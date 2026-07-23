module Garnix.Build.FodCheck
  ( withFodChecker,
    fodCheck,
    -- exported for testing:
    __findAllFodsRecursively,
    __classifyFodBuilder,
    __fodBuildArgs,
    __isSourceUnavailableError,
    __rebuildFod,
  )
where

import Control.Concurrent.Lifted (modifyMVar, modifyMVar_, newMVar, readMVar, swapMVar)
import Control.Lens ((<&>))
import Control.Monad.Extra (mapMaybeM)
import Cradle
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.Either.Extra (mapLeft)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe
import Data.Row (Rec, type (.+), type (.==))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Garnix.BuildLogs.Types (LogLine (LogLine))
import Garnix.DB qualified as DB
import Garnix.DB.FeatureFlags qualified as FeatureFlags
import Garnix.DB.FeatureFlags.Types qualified as FeatureFlags
import Garnix.Duration (fromMinutes)
import Garnix.Monad
import Garnix.Monad.Async (joinAll, resolve, spawn)
import Garnix.Monad.Bubbling
import Garnix.Monad.Metrics (timingAs)
import Garnix.Monad.Pool (withPoolM)
import Garnix.Monad.SubProcess (runSubProcess)
import Garnix.Nix.StorePath (unwrapDerivations)
import Garnix.Nix.Types qualified as Nix
import Garnix.NixConfig (addNixConfigEnvironment)
import Garnix.Prelude hiding (Alternative)
import Garnix.Types
import Garnix.YamlConfig qualified as YamlConfig
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
      -- Unambiguous conclusion: any FOD check that failed makes the run a
      -- failure. Fetch-looking stderr is builder-controlled and therefore
      -- cannot authorize a non-blocking skip.
      case errors of
        Left (errors :: [Text]) -> do
          reportToSummary $ show (length errors) <> " FOD checks failed."
          reportComplete (fodChecker ^. #runReporter) RunReportStatusFailure
        Right () -> reportComplete (fodChecker ^. #runReporter) RunReportStatusSuccess
  either rethrow pure actionResult

getFodChecker :: Reporter -> CommitInfo -> ProductPlan -> M (Maybe FodChecker)
getFodChecker reporter commitInfo plan = do
  garnixConfig <- YamlConfig.getConfig (fromMinutes $ plan ^. packageEvaluationTimeout)
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
  derivations <- decodeNixDerivations (StdoutRaw stdout)
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
    (Rec ("builder" .== Text .+ "env" .== NixDerivationShowEnvJson))

data NixDerivationShowEnvJson = NixDerivationShowEnvJson
  { outputHash :: Maybe Text,
    system :: Maybe Text
  }
  deriving (Generic, Show)

instance FromJSON NixDerivationShowEnvJson

decodeNixDerivations :: StdoutRaw -> M NixDerivationShowJson
decodeNixDerivations (StdoutRaw stdout) = do
  value :: Aeson.Value <- aesonDecode "nix derivation show output" parseJSON (cs stdout)
  either (\e -> throw $ DecodeError {original = cs stdout, message = "decoding derivations: " <> cs e}) pure
    $ Aeson.parseEither parseJSON (unwrapDerivations value)

getFodBuilder :: Nix.DrvPath -> M Text
getFodBuilder drvPath = do
  nixConfig <- view #userNixConfig
  stdout <-
    runSubProcess
      $ cmd "nix"
      & addArgs ["derivation", "show", cs drvPath :: Text]
      & addNixConfigEnvironment nixConfig
  derivations <- decodeNixDerivations stdout
  case Map.elems derivations of
    [derivation] -> pure $ derivation ^. #builder
    [] -> throw $ OtherError $ "nix derivation show returned no derivation for " <> cs drvPath
    _ -> throw $ OtherError $ "nix derivation show returned multiple derivations for " <> cs drvPath

-- | Diagnose derivations such as nixpkgs' pre-seeded bootstrap sources. Their
-- @builder@ is deliberately an explanatory error message rather than a program,
-- so no checker can execute it. This classification changes only the error
-- text: the FOD still fails closed and is never recorded as verified.
__classifyFodBuilder :: Text -> Maybe Text
__classifyFodBuilder builder
  | validExecutableBuilder = Nothing
  | otherwise =
      Just
        "This fixed-output derivation cannot be independently rebuilt: its builder field is not an executable path or Nix builtin. It may be a pre-seeded bootstrap source supplied only by a substituter. Garnix has not verified it and is failing closed."
  where
    validExecutableBuilder =
      ("/" `Text.isPrefixOf` builder || "builtin:" `Text.isPrefixOf` builder)
        && not (Text.any (`elem` ['\n', '\r']) builder)

getFodBuilderDiagnosis :: Nix.DrvPath -> M (Maybe Text)
getFodBuilderDiagnosis drvPath = do
  builderResult :: Either ErrorWithContext Text <- try $ getFodBuilder drvPath
  pure $ either (const Nothing) __classifyFodBuilder builderResult

checkFod :: FodChecker -> Nix.DrvPath -> System -> M (Either Text ())
checkFod fodChecker drvPath system = do
  log Informational $ "checking fod: " <> cs drvPath <> ", system: " <> system ^. systemTextIso
  result <- rebuildFod system drvPath
  case result of
    Left stderr -> do
      builderDiagnosis <- getFodBuilderDiagnosis drvPath
      let errorMessage =
            "Failure when checking FOD '"
              <> cs drvPath
              <> "':\n"
              <> maybe stderr (\diagnosis -> diagnosis <> "\n\nOriginal rebuild failure:\n" <> stderr) builderDiagnosis
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

-- | Kept as a regression seam for the historical source-unavailable bypass.
-- FOD stderr is emitted by code under verification, so no substring can prove
-- that a message came from a trusted fetcher rather than a builder deliberately
-- printing fetch-looking text. Every failed rebuild therefore fails closed.
__isSourceUnavailableError :: Text -> Bool
__isSourceUnavailableError _stderr = False

type NixBuildOutput = [Rec ("drvPath" .== Text .+ "outputs" .== Map.Map Text Text)]

-- | Build arguments for both phases of a FOD check. Deliberately omit
-- @--store@: the local daemon owns the canonical store, its substituters, and
-- paths already hydrated on the host. Passing a remote store here would create
-- a second store boundary. Disable distributed builders for this command so
-- the strict rebuild uses the canonical host daemon's FOD transport policy;
-- ordinary package builds remain distributed.
__fodBuildArgs :: Nix.DrvPath -> Bool -> [Text]
__fodBuildArgs drvPath shouldRebuild =
  [ "build",
    cs drvPath <> "^*",
    "--no-link",
    "--json",
    "--builders",
    ""
  ]
    <> ["--rebuild" | shouldRebuild]

-- | Prepare and then rebuild the original FOD through the canonical Nix
-- daemon store. The prepare phase may hydrate the expected output from the
-- host store or its substituters. The strict phase always executes the
-- original derivation unchanged on the canonical host daemon. Keeping FOD
-- verification local also guarantees that daemon-scoped compatibility
-- transport (when enabled) applies to legacy fetchers.
rebuildFod :: System -> Nix.DrvPath -> M (Either Text Text)
rebuildFod =
  curry $ mockable #rebuildFodMock $ \(_system, drvPath) -> withBubbling $ \bubble -> do
    nixConfig <- view #userNixConfig
    let runBuild shouldRebuild = do
          (exitCode, StdoutRaw (cs -> stdout), StderrRaw (cs -> stderr)) <-
            run
              $ cmd "nix"
              & addArgs (__fodBuildArgs drvPath shouldRebuild)
              & addNixConfigEnvironment nixConfig
          pure $ case exitCode of
            ExitFailure _ -> Left stderr
            ExitSuccess -> Right stdout
    void
      $ (bubble =<< runBuild False)
      <?> ("rebuildFod: preparing " <> cs drvPath)
    (bubble =<< runBuild True)
      <?> ("rebuildFod: checking " <> cs drvPath)

__rebuildFod :: System -> Nix.DrvPath -> M (Either Text Text)
__rebuildFod = rebuildFod
