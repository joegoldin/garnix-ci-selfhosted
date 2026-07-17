module Garnix.Build.FodCheck
  ( withFodChecker,
    fodCheck,
    -- exported for testing:
    __findAllFodsRecursively,
    __pickRemoteBuilderUrlFromMachinesFile,
    __parseMachinesFile,
  )
where

import Control.Concurrent.Lifted (modifyMVar, modifyMVar_, newMVar, readMVar, swapMVar)
import Control.Exception.Safe qualified as Safe
import Control.Lens ((<&>))
import Control.Monad.Extra (mapMaybeM)
import Cradle
import Data.Attoparsec.Text hiding (try, (<?>))
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Either.Extra (mapLeft)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe
import Data.Row (Rec, type (.+), type (.==))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.IO qualified as T
import Garnix.BuildLogs.Types (LogLine (LogLine))
import Garnix.DB qualified as DB
import Garnix.DB.FeatureFlags qualified as FeatureFlags
import Garnix.DB.FeatureFlags.Types qualified as FeatureFlags
import Garnix.Monad
import Garnix.Monad.Async (joinAll, resolve, spawn)
import Garnix.Monad.Bubbling
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Garnix.Monad.Metrics (timingAs)
import Garnix.Monad.Pool (withPoolM)
import Garnix.Monad.SubProcess (runSubProcess)
import Garnix.Nix.StorePath (unwrapDerivations)
import Garnix.Nix.Types qualified as Nix
import Garnix.NixConfig (addNixConfigEnvironment)
import Garnix.Prelude hiding (Alternative)
import Garnix.Types
import Garnix.YamlConfig qualified as YamlConfig
import System.Directory (doesFileExist)
import System.Metrics.Prometheus.Metric.Histogram qualified as Prometheus

withFodChecker :: Reporter -> CommitInfo -> ProductPlan -> (Maybe FodChecker -> M a) -> M a
withFodChecker reporter commitInfo plan action = do
  fodChecker <- getFodChecker reporter commitInfo plan
  let reportToSummary = case fodChecker of
        Just fodChecker -> \logLine -> reportLogs (fodChecker ^. #runReporter) $ LogLine (Just $ PackageName "FOD Summary") Nothing logLine
        Nothing -> const $ pure ()
  reportToSummary "Checking fixed output derivations..."
  -- The FOD run must ALWAYS reach a terminal state, even when the wrapped
  -- build/deploy flow throws (e.g. a failed deployment) — otherwise it sits
  -- Pending forever. Collect the action's outcome, complete the run from
  -- whatever checks did happen, then rethrow.
  actionResult <- try (action fodChecker)
  case fodChecker of
    Nothing -> pure ()
    Just fodChecker -> do
      promises <-
        swapMVar (fodChecker ^. #promises) Nothing
          <&> fromMaybe (error "impossible: should still be Just")
      -- A check that THROWS (rather than returning Left) must still complete
      -- the run.
      results <- try (resolve =<< joinAll promises)
      errors :: Either [Text] () <- case results of
        Right rs -> pure $ mapLeft (map snd . join) (collectErrors rs)
        Left e -> do
          let msg = "FOD checking failed with an internal error:\n" <> showDebug e
          log Error msg
          reportToSummary msg
          pure $ Left [msg]
      skipped <- readMVar $ fodChecker ^. #totalSkipped
      verified <- readMVar $ fodChecker ^. #totalVerified
      case skipped of
        0 -> pure ()
        1 -> reportToSummary "1 FOD was skipped because it was verified in previous garnix builds."
        skipped -> reportToSummary $ show skipped <> " FODs were skipped because they were verified in previous garnix builds."
      case verified of
        0 -> pure ()
        1 -> reportToSummary "1 FOD was verified."
        verified -> reportToSummary $ show verified <> " FODs were verified."
      case errors of
        Right () -> reportComplete (fodChecker ^. #runReporter) RunReportStatusSuccess
        Left (errors :: [Text]) -> do
          reportToSummary $ show (length errors) <> " FOD checks failed."
          reportComplete (fodChecker ^. #runReporter) RunReportStatusFailure
  either rethrow pure actionResult

getFodChecker :: Reporter -> CommitInfo -> ProductPlan -> M (Maybe FodChecker)
getFodChecker reporter commitInfo _plan = do
  garnixConfig <- YamlConfig.getConfig
  if garnixConfig ^. YamlConfig.fodChecks
    then do
      run <- DB.newRun "FOD checks" commitInfo
      runReporter' <- createNewRun reporter (ReportRun run)
      -- Like every other run kind (withRunReporter), the FOD run leaves
      -- "pending" on its first line of output. The FodChecker outlives any
      -- lexical scope, so it can't use withRunReporter itself.
      pendingRef <- liftIO $ newIORef True
      let runReporter =
            runReporter'
              { reportLogs = \logLine -> do
                  isFirst <- liftIO $ atomicModifyIORef' pendingRef (False,)
                  when isFirst $ DB.markRunRunning (_runId run)
                  reportLogs runReporter' logLine
              }
      -- No billing in this fork: FOD checks are available to everyone.
      Just <$> mkFodChecker runReporter
    else do
      randomlyEnabled <- FeatureFlags.isFeatureOn FeatureFlags.FodChecks
      if randomlyEnabled
        then Just <$> mkFodChecker mempty
        else pure Nothing
  where
    mkFodChecker :: RunReporter -> M FodChecker
    mkFodChecker runReporter =
      FodChecker runReporter
        <$> newMVar 0
        <*> newMVar 0
        <*> newMVar (Just [])
        <*> newMVar mempty

fodCheck :: Maybe FodChecker -> Nix.DrvPath -> M ()
fodCheck = curry $ mockable #fodCheckMock $ \(fodChecker, drvPath) -> do
  withTextSpan ("fod_check_package", cs drvPath) $ do
    case fodChecker of
      Nothing -> pure ()
      Just fodChecker -> do
        modifyMVar_ (fodChecker ^. #promises) $ \case
          Nothing -> do
            log Critical "withFodChecker already exited"
            pure Nothing
          Just promises -> do
            new <- spawn (runFodCheck fodChecker drvPath)
            pure $ Just (new : promises)

runFodCheck :: FodChecker -> Nix.DrvPath -> M (Either [(Nix.DrvPath, Text)] ())
runFodCheck fodChecker drvPath = do
  withMessage "running fodCheck" $ do
    timingAs #fodCheckTime $ do
      logDuration "FOD check" $ do
        allFods <- __findAllFodsRecursively drvPath
        notStartedOrDone <- getNotStartedOrDone fodChecker allFods
        fods <- DB.keepUnverifiedFods notStartedOrDone
        modifyMVar_ (fodChecker ^. #totalSkipped) $ pure . (+ (length notStartedOrDone - length fods))
        (liftIO . Prometheus.observe (fromIntegral $ length fods))
          =<< view (#metrics . #fodCheckBatchSize)
        errors <- forConcurrently (toList fods) $ \(drvPath, system) -> do
          withPoolM fodCheckPool () $ do
            mapLeft (drvPath,) <$> checkFod fodChecker drvPath system
        pure $ collectErrors errors

getNotStartedOrDone :: FodChecker -> Set (Nix.DrvPath, System) -> M (Set (Nix.DrvPath, System))
getNotStartedOrDone fodChecker set = do
  modifyMVar (fodChecker ^. #startedOrDone) $ \current -> do
    pure
      ( current <> Set.map fst set,
        set & Set.filter (\(drvPath, _) -> drvPath `Set.notMember` current)
      )

collectErrors :: [Either e ()] -> Either [e] ()
collectErrors eithers = case catMaybes $ map (either Just (const Nothing)) eithers of
  [] -> Right ()
  errors -> Left errors

__findAllFodsRecursively :: Nix.DrvPath -> M (Set (Nix.DrvPath, System))
__findAllFodsRecursively drvPath = do
  nixConfig <- view #userNixConfig
  StdoutRaw stdout <-
    runSubProcess
      $ cmd "nix"
      & addArgs ["derivation", "show", "--recursive", cs drvPath :: Text]
      & addNixConfigEnvironment nixConfig
  value :: Aeson.Value <- aesonDecode "nix derivation show output" parseJSON (cs stdout)
  derivations :: NixDerivationShowJson <-
    either (\e -> throw $ DecodeError {original = cs stdout, message = "decoding derivations: " <> cs e}) pure
      $ Aeson.parseEither parseJSON (unwrapDerivations value)
  (Set.fromList <$>) $ flip mapMaybeM (Map.toList derivations) $ \(drvPathText, info) -> do
    case (info ^. #env . #outputHash, info ^. #env . #system) of
      (Nothing, _) -> pure Nothing
      (Just _, Nothing) ->
        throw
          $ DecodeError
            { original = cs stdout,
              message = "fod doesn't have an `env.system` field."
            }
      (Just _fodDerivation, Just system) -> do
        -- Older nix keys the map by the full store path, newer nix by the bare
        -- @<hash>-name.drv@; normalize to a full store path either way.
        let drvStorePath =
              if "/nix/store/" `Text.isPrefixOf` drvPathText
                then drvPathText
                else "/nix/store/" <> drvPathText
        case Nix.parseDrvPath drvStorePath of
          Left err -> throw $ DecodeError {original = cs stdout, message = "Failed to parse drv path: " <> err}
          Right drvPath -> pure $ Just (drvPath, system ^. re systemTextIso)

-- | The inner @{<drvPath>: {...}}@ map of @nix derivation show@ (after
-- 'unwrapDerivations' has stripped the newer nix @"derivations"@ wrapper).
type NixDerivationShowJson =
  Map.Map
    Text
    (Rec ("env" .== NixDerivationShowEnvJson))

data NixDerivationShowEnvJson = NixDerivationShowEnvJson
  { outputHash :: Maybe Text,
    system :: Maybe Text
  }
  deriving (Generic, Show)

instance FromJSON NixDerivationShowEnvJson

checkFod :: FodChecker -> Nix.DrvPath -> System -> M (Either Text ())
checkFod fodChecker drvPath system = do
  log Informational $ "checking fod: " <> cs drvPath <> ", system: " <> system ^. systemTextIso
  result <- rebuildFod system drvPath
  case result of
    Left stderr -> do
      let errorMessage =
            "Failure when checking FOD '"
              <> cs drvPath
              <> "':\n"
              <> stderr
      log Error errorMessage
      reportLogs (fodChecker ^. #runReporter) $ LogLine (Just $ PackageName $ cs drvPath <> " (failed)") Nothing errorMessage
      pure $ Left errorMessage
    Right stdout -> do
      modifyMVar_ (fodChecker ^. #totalVerified) $ pure . (+ 1)
      storePath :: Nix.StorePath <- do
        parsed <- aesonDecode "nix build output" (parseJSON @NixBuildOutput) stdout
        case parsed of
          [derivation] -> case Map.elems (derivation ^. #outputs) of
            [output] -> case Nix.parseStorePath output of
              Right storePath -> pure storePath
              Left error -> throw $ DecodeError {original = stdout, message = error}
            _ -> throw $ OtherError "impossible: fods cannot have multiple outputs"
          _ -> throw $ OtherError "impossible: more than one derivation returned"
      DB.addVerifiedFod drvPath storePath
      pure $ Right ()

type NixBuildOutput = [Rec ("drvPath" .== Text .+ "outputs" .== Map.Map Text Text)]

-- | Rebuild a FOD, ignoring the existing output, so a lying hash surfaces.
-- Upstream rebuilds on a remote builder from its fleet; a self-host box
-- usually has no builder for its own system (or no /etc/nix/machines at
-- all), so when none matches we rebuild locally — `nix build --rebuild`
-- re-fetches the FOD and fails on hash mismatch either way.
rebuildFod :: System -> Nix.DrvPath -> M (Either Text Text)
rebuildFod = do
  curry $ mockable #rebuildFodMock $ \(system, drvPath) -> withBubbling $ \bubble -> do
    nixConfig <- view #userNixConfig
    remoteBuilderUrl <- __pickRemoteBuilder system
    (exitCode, StdoutRaw (cs -> stdout), StderrRaw (cs -> stderr)) <- case remoteBuilderUrl of
      Just url -> do
        sshKey <- liftIO remoteBuilderSshKeyPath
        (bubble =<< copyClosure sshKey drvPath url)
          <?> ("rebuildFod: copying closure of " <> cs drvPath <> " to " <> url)
        run
          $ cmd "nix"
          & addArgs
            [ "build",
              cs drvPath <> "^*",
              "--no-link",
              "--json",
              "--rebuild",
              "--store",
              url,
              "--eval-store",
              "auto"
            ]
          & modifyEnvVar "NIX_SSHOPTS" (const $ Just $ unwords (remoteBuilderSshArgs sshKey))
          & addNixConfigEnvironment nixConfig
      Nothing ->
        run
          $ cmd "nix"
          & addArgs
            ([ "build",
               cs drvPath <> "^*",
               "--no-link",
               "--json",
               "--rebuild"
             ] ::
               [Text]
            )
          & addNixConfigEnvironment nixConfig
    bubble $ case exitCode of
      ExitFailure _ -> Left stderr
      ExitSuccess -> Right stdout

-- Untested.
copyClosure :: FilePath -> Nix.DrvPath -> Text -> M (Either Text ())
copyClosure sshKey drvPath remoteBuilderUrl = do
  nixConfig <- view #userNixConfig
  (exitCode, StderrRaw (cs -> stderr)) <-
    Cradle.run
      $ cmd "nix"
      & Cradle.addArgs
        [ "copy",
          "--no-check-sigs",
          "--to",
          remoteBuilderUrl,
          cs drvPath <> "^*"
        ]
      & addNixConfigEnvironment nixConfig
      & Cradle.modifyEnvVar "NIX_SSHOPTS" (const $ Just $ unwords (remoteBuilderSshArgs sshKey))
      & Cradle.silenceStderr
  case exitCode of
    ExitFailure _ -> pure $ Left stderr
    ExitSuccess -> pure $ Right ()

remoteBuilderSshArgs :: FilePath -> [String]
remoteBuilderSshArgs sshKey = ["-i", sshKey]

-- | Upstream's sops layout installs a garnix-readable copy of the remote
-- builder key under the `_garnix` suffix; the agenix self-host layout
-- installs it under its plain name. Use whichever exists.
remoteBuilderSshKeyPath :: IO FilePath
remoteBuilderSshKeyPath = do
  let upstream = "/run/secrets/garnix_server_remote_builder_ssh_garnix"
  doesFileExist upstream <&> \case
    True -> upstream
    False -> "/run/secrets/garnix_server_remote_builder_ssh"

-- | A remote builder for the system, if the host has a machines file that
-- names one; 'Nothing' means rebuild locally.
__pickRemoteBuilder :: System -> M (Maybe Text)
__pickRemoteBuilder system =
  liftIO (Safe.tryIO (T.readFile "/etc/nix/machines")) >>= \case
    Left _noMachinesFile -> pure Nothing
    Right contents -> __pickRemoteBuilderUrlFromMachinesFile system contents

__pickRemoteBuilderUrlFromMachinesFile :: System -> Text -> M (Maybe Text)
__pickRemoteBuilderUrlFromMachinesFile (replaceBuiltinSystem -> system) machinesFile =
  case __parseMachinesFile machinesFile of
    Left error -> throw $ OtherError $ "cannot parse /etc/nix/machines: " <> error
    Right machines -> case Map.lookup system machines of
      Nothing -> pure Nothing
      Just ms -> Just <$> randomElement ms

replaceBuiltinSystem :: System -> System
replaceBuiltinSystem = \case
  OtherSystem "builtin" -> X8664Linux
  other -> other

__parseMachinesFile :: Text -> Either Text (Map.Map System [Text])
__parseMachinesFile machinesFile =
  mapLeft cs $ parseOnly machines machinesFile
  where
    machines :: Parser (Map System [Text])
    machines = do
      _ <- skipSpace
      lines <- sepBy line (many1 endOfLine) <* skipSpace <* endOfInput
      pure $ Map.fromListWith (<>) $ join $ map (\(builder, systems) -> map (,[builder]) systems) lines

    line :: Parser (Text, [System])
    line = do
      _ <- many (char ' ')
      machine <- cs <$> manyTill anyChar (many1 (char ' '))
      systems <- sepBy (cs <$> many (satisfy (`notElem` [' ', ',']))) (char ',') <* char ' '
      _ <- many (satisfy (/= '\n'))
      pure (machine, fmap (^. re systemTextIso) systems)
