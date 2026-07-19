{-# LANGUAGE OverloadedLists #-}

module Garnix.Build.Action
  ( getActionAppAttributes,
    run,
  )
where

import Control.Concurrent.Async.Lifted (waitEither, withAsync)
import Control.Lens
import Cradle (ProcessConfiguration)
import Cradle qualified
import Data.Aeson ((.:))
import Data.Aeson qualified as JSON
import Data.Aeson.Types qualified as JSON
import Data.ByteString qualified as BS
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Garnix.API.Keys qualified as Keys
import Garnix.Async qualified as Async
import Garnix.Attribute
import Garnix.DB qualified as DB
import Garnix.Duration
import Garnix.FlakeInputAuthorization (githubAccessTokenNixConfig)
import Garnix.Monad
import Garnix.Nix.StorePath (withStorePath)
import Garnix.Nix.Types qualified as Nix
import Garnix.NixConfig (addNixConfigEnvironment)
import Garnix.NixConfig qualified as NixConfig
import Garnix.Prelude
import Garnix.Reporters.Utils (runWithRunReporter, withRunReporter)
import Garnix.Request
import Garnix.SafeUnix (safeCreatePipe)
import Garnix.Sandbox
import Garnix.Types
import Garnix.YamlConfig (Action (..), ActionSandboxType (..), githubTokenModeScope, sandboxType)
import Garnix.YamlConfig qualified as Config
import System.Directory qualified as IO
import System.IO (hClose, hFlush)

getActionAppAttributes :: Config.GarnixConfig -> [(Attribute, Action)]
getActionAppAttributes config = go <$> config ^. Config.actions
  where
    go :: Config.Action -> (Attribute, Action)
    go a@(Config.Action package _ _ _ _) =
      ( Attribute
          { _attributePackageType = TypeApp,
            _attributeSystem = Just X8664Linux,
            _attributePackageName = Just package,
            _attributeExtension = Nothing
          },
        a
      )

allowedSharedResourcesUsers :: [Text]
allowedSharedResourcesUsers =
  T.toLower
    <$> [ "garnix-io",
          "bellroy",
          "emanueljg",
          "psychefoundation",
          "imiron-io",
          "oliverlee",
          "jameshaydon",
          "ilyakooo0",
          "montelot",
          "soenkehahn"
        ]

run :: FlakeDir -> RepoConfig -> Reporter -> CommitInfo -> Attribute -> Action -> Build -> M ()
run flakeDir repoConfig reporter commitInfo attr actionConfig build =
  withTextSpan ("action_run", review asAttribute attr) $ do
    DB.markBuildRunning (build ^. id)
    ensureBuildIsApp build
    derivation <- getBuildDerivation build
    command <- evaluateAppExecPath flakeDir repoConfig build
    let name = "action " <> maybe "Unknown" cs (attr ^. packageName)
    githubTokenVars <- actionGithubTokenEnv commitInfo actionConfig
    let environmentVars =
          Map.fromList
            [ ("GARNIX_CI", "true"),
              ("GARNIX_BRANCH", maybe "" getBranch $ build ^. branch),
              ("GARNIX_COMMIT_SHA", build ^. gitCommit . to getCommitHash)
            ]
            <> githubTokenVars
    run <- DB.newRun name commitInfo
    withRunReporter reporter (ReportRun run) $ \runReporter -> withStorePath build "out" $ \_ -> do
      ensureAllowedSandboxType (build ^. repoUser) actionConfig
      validateApplication command
      copyClosure derivation <?> "Action: copy closure"
      privKey <- case build ^. prFromFork of
        Nothing -> do
          Just . snd <$> Keys.getActionKeys (build ^. repoUser) (build ^. repoName) (build ^. package)
        Just _fork -> pure Nothing
      abortOnRunCancellation (_runId run)
        $ withTimeout
        $ runAction runReporter actionConfig command privKey environmentVars <?> "Action: execute"
  where
    withTimeout :: M a -> M a
    withTimeout inner = do
      outerActionTimeout <-
        view (#action . #timeoutDuration)
          <&> addDuration (fromMinutes @Int 10)
      Async.timeout outerActionTimeout inner
        >>= \case
          Nothing -> throw ActionExecutionTimeout
          Just r -> pure r

    -- Race the action against its run row being marked Cancelled (via the
    -- commit page's Cancel-all); mirrors the build path's
    -- abortOnCancellation. The run's status is already Cancelled in the DB,
    -- so just drop the process and return.
    abortOnRunCancellation :: RunId -> M () -> M ()
    abortOnRunCancellation runId inner = do
      let go = do
            DB.getRun runId >>= \case
              Just r | _runStatus r == Just Cancelled -> pure ()
              _ -> threadDelay (fromSeconds @Int 10) >> go
      withAsync inner $ \innerAsync ->
        withAsync go $ \isCancelled ->
          waitEither innerAsync isCancelled >>= \case
            Left () -> pure ()
            Right () -> log Notice "Action run was cancelled; aborting."

    ensureBuildIsApp :: Build -> M ()
    ensureBuildIsApp build =
      case build ^. packageType of
        TypeApp -> pure ()
        pkgType -> do
          log Critical $ "Broken invariant: should not try to run something that's not an action: " <> show attr <> " (with type " <> show pkgType <> ")"
          throw $ OtherError "Internal error: attempted to run an action on an attribute that's not an action."

    getBuildDerivation :: Build -> M Nix.DrvPath
    getBuildDerivation build = do
      let drv = case build ^. drvPath of
            Nothing -> Left "build has no drvPath"
            Just drv' -> Nix.DrvPath <$> Nix.parseStorePath drv'
      case drv of
        Left err -> do
          log Warning $ "Unexpected: could not find the app derivation: " <> err
          throw $ OtherError "Cannot run action: could not find the derivation needed to run the application. Did you make sure the 'program' is an executable path that's part of a derivation?"
        Right derivation -> pure derivation

-- | When an action opts into a GitHub token (garnix.yaml @githubToken:
-- descoped|repo@), mint a short-lived, scoped GitHub App installation access
-- token and expose it to the action as both a @GITHUB_TOKEN@ env var and nix
-- @access-tokens = github.com=…@ (threaded via @NIX_CONFIG@, the same setting
-- 'NixConfig.addNixConfigEnvironment' threads for build nix invocations), so
-- the action's @github:@ flake-input fetches authenticate instead of hitting
-- GitHub's 60/hr anonymous rate limit.
--
-- GitHub-only: for non-GitHub forges (e.g. Gitea, which has no App
-- installation) this mints nothing and returns no extra environment. The token
-- value is never logged — it only ever reaches the action process' environment
-- (and, should it surface in action output/logs, is redacted by
-- 'obfuscateGithubToken', which matches @ghs_@ installation tokens).
actionGithubTokenEnv :: CommitInfo -> Action -> M (Map.Map Text Text)
actionGithubTokenEnv commitInfo actionConfig =
  case (commitInfo ^. repoInfo . forge, githubTokenModeScope (actionConfig ^. githubToken)) of
    (ForgeGithub, Just scope) -> do
      let owner = commitInfo ^. repoInfo . ghRepoOwner
          repo = commitInfo ^. repoInfo . ghRepoName
      token <- mintScopedActionToken owner repo scope
      let nixConfig = githubAccessTokenNixConfig token
      pure
        $ Map.fromList
          [ ("GITHUB_TOKEN", getGhToken token),
            ("NIX_CONFIG", cs (NixConfig.formatConfig nixConfig))
          ]
    _ -> pure mempty

validateApplication :: Nix.AppExecPath -> M ()
validateApplication (Nix.AppExecPath path) = do
  when (not $ "/nix/store/" `T.isPrefixOf` path)
    $ throw
    $ ActionPreconditionNixStore path
  pathExists <- liftIO $ IO.doesPathExist (cs path)
  when (not pathExists)
    $ throw
    $ ActionPreconditionFileExists path

ensureAllowedSandboxType :: GhRepoOwner -> Action -> M ()
ensureAllowedSandboxType owner actionConfig = do
  -- The shared-resources allowlist is a garnix-cloud restriction; in self-host
  -- mode the operator owns all resources, so any repo may use it.
  selfHost <- view #selfHostMode
  when
    ( not selfHost
        && T.toLower (getGhLogin $ getGhRepoOwner owner)
        `notElem` allowedSharedResourcesUsers
        && actionConfig
        ^. sandboxType == SharedResources
    )
    $ throw
    $ ActionSandboxTypeNotAllowed "shared-resources"

copyClosure :: Nix.DrvPath -> M ()
copyClosure path = do
  actionTimeout <- view $ #action . #timeoutDuration
  retryingFor actionTimeout $ do
    actionHost <- view $ #action . #runnerHost
    sshKey <- view $ #action . #runnerSshKey
    (ip, sshArgs) <- sshArgsFor actionHost sshKey
    nixConfig <- view #userNixConfig
    let args = ["copy", "--no-check-sigs", "--to", "ssh-ng://action-runner@" <> cs ip, cs path <> "^*"]
    result <-
      Cradle.run
        $ Cradle.cmd "nix"
        & Cradle.addArgs args
        & NixConfig.addNixConfigEnvironment nixConfig
        & Cradle.modifyEnvVar "NIX_SSHOPTS" (const $ Just $ cs $ T.intercalate " " sshArgs)
        & Cradle.silenceStderr
    case result of
      (Cradle.ExitFailure code, Cradle.StdoutRaw out, Cradle.StderrRaw err) -> do
        log Warning
          $ "copyClosure error stdout ("
          <> cs out
          <> ") stderr ("
          <> cs err
          <> ")"
        throw RunProcessError {command = "nix", arguments = args, stdErr = cs err, stdOut = cs out, exitCode = code}
      (Cradle.ExitSuccess, Cradle.StdoutRaw out, Cradle.StderrRaw err) -> do
        log Informational
          $ "copyClosure success ("
          <> cs out
          <> ") stderr ("
          <> cs err
          <> ")"

runAction :: RunReporter -> Action -> Nix.AppExecPath -> Maybe PrivateKey -> Map.Map Text Text -> M ()
runAction runReporter actionConfig path actionPrivateKey environmentVars = do
  repoSecretsKey <- view #repoSecretsEncryptionKeyPath
  privKey <- case actionPrivateKey of
    Nothing -> pure "none"
    Just key -> do
      liftIO (unsafeDecryptPrivateKey key repoSecretsKey) >>= \case
        Left _ -> throw ActionKeyDecryptionFailure
        Right k -> pure k
  proc <- runSshOnActionRunner actionConfig (Nix.getAppExecPath path) privKey environmentVars
  exitCode <- runWithRunReporter runReporter proc
  -- The self-host runner wraps every sandbox type in coreutils `timeout`
  -- (exit 124), so report a timeout regardless of sandbox type.
  when (exitCode == Cradle.ExitFailure 124)
    $ do
      throw ActionExecutionTimeout
  when
    ( exitCode
        == Cradle.ExitFailure 255
        && actionConfig
        ^. sandboxType == FastStartup
    )
    $ do
      throw ActionExecutionTimeout
  let status = case exitCode of
        Cradle.ExitSuccess -> RunReportStatusSuccess
        _ -> RunReportStatusFailure
  reportComplete runReporter status

copyRepoToActionRunner :: M FilePath
copyRepoToActionRunner = do
  repo <- view #workingDir
  actionHost <- view $ #action . #runnerHost
  sshKey <- view $ #action . #runnerSshKey
  unlessM (liftIO $ IO.doesDirectoryExist (repo </> ".git"))
    $ throw
    $ OtherError
    $ "Expected directory "
    <> cs repo
    <> "to be the repo root"
  (ip, sshArgs) <- sshArgsFor actionHost sshKey
  (_, port) <- splitPortFromIP actionHost
  (sshExitCode, Cradle.StdoutTrimmed tempDir, Cradle.StderrRaw sshErr) <-
    Cradle.run $ Cradle.cmd "ssh"
      & Cradle.addArgs (["action-runner@" <> ip] <> sshArgs <> ["--", "mktemp", "-d"])
  unless (sshExitCode == Cradle.ExitSuccess)
    $ throw
    $ OtherError
    $ "ssh failed. Error: <> "
    <> show sshErr
  (rsyncExitCode, Cradle.StderrRaw rsyncErr) <-
    Cradle.run $ Cradle.cmd "rsync"
      -- Same host-key stance as sshArgsFor: a fresh runner host (every CI
      -- run boots a new VM) fails strict host-key verification otherwise.
      & Cradle.addArgs ["-a", "-e", "ssh -p " <> port <> " -i " <> sshKey <> " -oBatchMode=yes -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null", cs (repo <> "/"), "action-runner@[" <> ip <> "]:" <> tempDir]
  unless (rsyncExitCode == Cradle.ExitSuccess)
    $ throw
    $ OtherError
    $ "rsync failed. Error: <> "
    <> show rsyncErr
  return (cs tempDir)

runSshOnActionRunner :: Action -> Text -> Text -> Map.Map Text Text -> M Cradle.ProcessConfiguration
runSshOnActionRunner actionConfig command stdin environmentVars = do
  actionHost <- view $ #action . #runnerHost
  sshKey <- view $ #action . #runnerSshKey
  actionTimeout <- view $ #action . #timeoutDuration
  (ip, sshArgs) <- sshArgsFor actionHost sshKey
  repoDirEnvVar <-
    if actionConfig ^. Config.withRepoContents
      then do
        log Informational "Copying repo contents"
        dir <- copyRepoToActionRunner
        pure $ "ACTION_REPO_DIR=" <> dir
      else do
        log Informational "Running without repo contents"
        pure ""
  let actionRunnerCmd = case actionConfig ^. sandboxType of
        FastStartup -> "action-runner"
        SharedResources -> "bwrap-action-runner"
  let args =
        ["action-runner@" <> ip]
          <> sshArgs
          <> ["--"]
          <> [ T.unwords
                 $ ( ( environmentVars
                         & Map.toList
                         & fmap (\(k, v) -> k <> "=" <> shellEscape v)
                     )
                       <> [cs repoDirEnvVar]
                   )
                 <> [ actionRunnerCmd,
                      shellEscape command,
                      shellEscape $ show @Int $ floor $ toSeconds actionTimeout
                    ]
             ]
  (readEnd, writeEnd) <- liftIO safeCreatePipe
  void . fork . liftIO $ do
    T.hPutStr writeEnd stdin
    hFlush writeEnd
    hClose writeEnd
  pure
    $ Cradle.cmd "ssh"
    & Cradle.addArgs args
    & Cradle.setStdinHandle readEnd
  where
    shellEscape :: Text -> Text
    shellEscape t = "'" <> T.replace "'" "'\"'\"'" t <> "'"

sshArgsFor :: Text -> Text -> M (Text, [Text])
sshArgsFor server key = do
  (i, port) <- splitPortFromIP server
  pure
    ( i,
      [ "-q",
        "-o",
        "BatchMode=yes",
        -- Fail fast on an unreachable action runner instead of hanging the
        -- run for the whole action timeout with no output.
        "-o",
        "ConnectTimeout=15",
        -- The self-host action runner is a local user (often 127.0.0.1) whose
        -- host key isn't in the garnix user's known_hosts; don't let a
        -- host-key prompt fail the (BatchMode) connection.
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-p",
        port,
        "-i",
        cs key
      ]
    )

splitPortFromIP :: Text -> M (Text, Text)
splitPortFromIP ip = case T.splitOn ":" ip of
  [_] -> pure (ip, "22")
  [ip', p] -> pure (ip', p)
  _ -> throw $ OtherError ("Action host IP not valid: " <> ip)

evaluateAppExecPath :: FlakeDir -> RepoConfig -> Build -> M Nix.AppExecPath
evaluateAppExecPath flakeDir repoConfig build = do
  nixConfig <- view #userNixConfig
  workingDir <- view #workingDir
  cacheDir <- getNixXdgCacheDir
  let appDerivation = "a: [{ run = a.program; }]"
  attr <- localAttr flakeDir . addNixosExtension . attribute $ build
  (exitCode, stdout, Cradle.StderrRaw stderr) <-
    (>>= Cradle.run)
      $ Cradle.cmd "comment"
      & Cradle.addArgs
        [ buildComment build,
          "--",
          "prlimit",
          "--as=" <> show (toBytes $ repoConfig ^. maxEvalMemory),
          "nix",
          "eval",
          attr,
          "--apply",
          appDerivation,
          "--json"
        ]
      & addNixConfigEnvironment nixConfig
      & Cradle.setWorkingDir workingDir
      & pure
      & inNixSandbox [] (Just cacheDir)
  case exitCode of
    Cradle.ExitFailure _ -> throw $ ActionEvaluationFailure $ cs stderr
    Cradle.ExitSuccess -> errorOnParseFailure $ parseNixEvalOutput stdout
  where
    errorOnParseFailure :: Maybe Nix.AppExecPath -> M Nix.AppExecPath
    errorOnParseFailure =
      \case
        Nothing -> do
          log Warning "Unexpected: could not find the action path to run."
          throw $ OtherError "Cannot run action: could not find the application's path. Did you correctly supply the app 'program'?"
        Just app -> pure app

    parseNixEvalOutput :: Cradle.StdoutRaw -> Maybe Nix.AppExecPath
    parseNixEvalOutput (Cradle.StdoutRaw stdout) =
      JSON.decode (BS.fromStrict stdout) >>= singletonList >>= JSON.parseMaybe go
      where
        singletonList :: JSON.Value -> Maybe JSON.Value
        singletonList =
          \case
            JSON.Array [single] -> Just single
            _ -> Nothing

        go :: JSON.Value -> JSON.Parser Nix.AppExecPath
        go = JSON.withObject "app" $ \o ->
          Nix.AppExecPath <$> o .: "run"
