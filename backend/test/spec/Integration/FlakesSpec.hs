module Integration.FlakesSpec (spec) where

import Control.Concurrent qualified
import Control.Monad
import Cradle
import Data.Aeson (Options (rejectUnknownFields), defaultOptions, genericParseJSON)
import Data.Char (isSpace)
import Data.Functor ((<&>))
import Data.IORef.Lifted (newIORef, readIORef)
import Data.IntMap qualified as IntMap
import Data.Yaml
import Database.PostgreSQL.Typed (pgSQL)
import Garnix.API.GhWebhooks (ghWebhookPullRequest)
import Garnix.BuildLogs (processLogsForGithub)
import Garnix.DB qualified as DB
import Garnix.GithubInterface
import Garnix.Monad
import Garnix.Monad.Async (resolve)
import Garnix.Prelude
import Garnix.TestHelpers
import Garnix.TestHelpers.GithubInterface.Deprecated qualified as Deprecated
import Garnix.TestHelpers.Monad (cleanDbConn, getGithubAppInstallationId, suppressLogsWhenPassing, withDevSecrets, withTestEnvironment)
import Garnix.Types hiding (base, context, description, head, name, packageType, repo)
import GitHub qualified as GH
import GitHub.App.Auth qualified as GHA
import System.Directory
import System.IO
import System.IO.Temp
import System.Process (callProcess, readProcessWithExitCode)
import Test.Hspec
import Text.Regex.PCRE.Light qualified as R
import Turtle qualified

spec :: Spec
spec = removePrivateSourcePathsFromNixStore $ do
  describe "the flakes spec @slow" $ do
    testDirs <- runIO getTests

    it "has at least one dir" $ do
      null testDirs `shouldBe` False

    forM_ testDirs $ \(dir, fspec) ->
      context dir
        $ it (cs $ description fspec)
        $ do
          testFlakeSpec dir fspec

-- | These are all the private inputs that we use for integration tests.
privateSourceStorePaths :: [FilePath]
privateSourceStorePaths =
  [ -- joegoldin/garnix-integration-minimal#afca9df1517408cc37f1eaa465b5fe178d0318ed
    "/nix/store/qzmfnb314ld81zipnm95yhp8gcjvxmnx-source",
    -- joegoldin/garnix-integration-private-input#aa4852f2ea61e91af698f8e48bc3ecc36211524f
    "/nix/store/kiq34nk3kjj4mf2a8xp7r3ypv0b3ima6-source"
  ]

removePrivateSourcePathsFromNixStore :: Spec -> Spec
removePrivateSourcePathsFromNixStore = before_ $ do
  garnixRunDirs <-
    map ("/tmp/" <>)
      . filter ("garnix-runs-" `isPrefixOf`)
      <$> listDirectory "/tmp"
  forM_ garnixRunDirs $ \dir ->
    callProcess "rm" [dir, "-rf"]
  forM_ privateSourceStorePaths $ \path -> do
    garbageCollectStorePath path
    doesExist <- doesDirectoryExist path
    when doesExist $ do
      error "private source path still in store"

garbageCollectStorePath :: FilePath -> IO ()
garbageCollectStorePath path = do
  assertNoGcRoots
  referrers <- lines <$> runProcess "nix-store" ["--query", "--referrers", path]
  forM_ referrers garbageCollectStorePath
  when (".drv" `isSuffixOf` path) $ do
    outputs <- lines <$> runProcess "nix-store" ["--query", "--outputs", path]
    forM_ outputs garbageCollectStorePath
  deriverPath <- getDeriver path
  -- Best effort, and deliberately a separate command: nix records a deriver even
  -- after the .drv itself has been garbage collected, so asking to delete both
  -- at once can fail wholesale on the stale .drv and leave the source path (the
  -- one this hook actually has to remove) in the store.
  forM_ deriverPath $ \drv ->
    void $ runProcessMaybe "nix-store" ["--delete", drv]
  deleteStorePath path
  where
    -- The roots check above is only valid at the instant it runs: GCing the
    -- referrers takes a while, and a concurrent nix process (the backend's own
    -- in-flight builds — this is the @slow integration suite) can take a
    -- temporary root on the path in the meantime, so the delete then fails with
    -- "since it is still alive". That is the same transient-root situation
    -- assertNoGcRoots already waits out for /proc roots, just surfacing one step
    -- later, so wait it out here too instead of failing the suite.
    deleteStorePath :: FilePath -> IO ()
    deleteStorePath toDelete =
      let go (n :: Int) = do
            (exitCode, _, stderr') <-
              readProcessWithExitCode "nix-store" ["--delete", toDelete] ""
            case exitCode of
              ExitSuccess -> pure ()
              ExitFailure _
                -- Someone else won the race and removed it: that is the outcome
                -- we wanted anyway.
                | "is not valid" `isInfixOf` stderr' -> pure ()
                | "still alive" `isInfixOf` stderr' && n > 0 -> do
                    hPutStrLn
                      System.IO.stderr
                      "path is still alive (concurrent nix run?), waiting and retrying delete..."
                    Control.Concurrent.threadDelay 50000
                    -- Re-query the roots: besides reporting them, this prunes
                    -- stale auto-gcroots (the /tmp/garnix-runs-* result symlinks
                    -- removed above leave some behind), which is often what is
                    -- keeping the path alive.
                    void $ runProcessMaybe "nix-store" ["--query", "--roots", toDelete]
                    go (n - 1)
                | otherwise -> do
                    hPutStrLn System.IO.stderr stderr'
                    -- Follow nix's own advice from the "still alive" message, so
                    -- a repeat failure in CI records WHICH root held the path
                    -- rather than just that something did.
                    roots <- runProcessMaybe "nix-store" ["--query", "--roots", toDelete]
                    referrers' <- runProcessMaybe "nix-store" ["--query", "--referrers", toDelete]
                    hPutStrLn System.IO.stderr $ "roots of " <> toDelete <> ":\n" <> maybe "(query failed)" (\s -> s) roots
                    hPutStrLn System.IO.stderr $ "referrers of " <> toDelete <> ":\n" <> maybe "(query failed)" (\s -> s) referrers'
                    error . cs $ "command failed: nix-store --delete " <> toDelete
       in go 1000

    assertNoGcRoots =
      let go (n :: Int) = do
            gcRoots <- lines <$> runProcess "nix-store" ["--query", "--roots", path]
            case gcRoots of
              [] -> pure ()
              _ : _ -> do
                let procGcRoots = filter ("/proc" `isPrefixOf`) gcRoots
                if procGcRoots == gcRoots && n > 0
                  then do
                    hPutStrLn System.IO.stderr "found gc roots in /proc, waiting for them to disappear..."
                    Control.Concurrent.threadDelay 50000
                    go (n - 1)
                  else error $ "garbageCollectStorePath: cannot remove path because of gc roots: " <> show gcRoots
       in go 1000

    getDeriver :: String -> IO (Maybe FilePath)
    getDeriver path = do
      maybePath <- runProcessMaybe "nix-store" ["--query", "--deriver", path]
      return $ maybePath >>= checkPath
      where
        checkPath path
          | "unknown-deriver" `isInfixOf` path || all isSpace path = Nothing
          | otherwise = Just . dropWhileEnd isSpace $ path

    runProcessMaybe :: String -> [String] -> IO (Maybe String)
    runProcessMaybe command args = do
      (exitCode, stdout, _) <- readProcessWithExitCode command args ""
      case exitCode of
        ExitSuccess -> pure $ Just stdout
        ExitFailure _ -> pure Nothing

    runProcess :: String -> [String] -> IO String
    runProcess command args = do
      (exitCode, stdout, stderr) <- readProcessWithExitCode command args ""
      case exitCode of
        ExitSuccess -> pure stdout
        ExitFailure _ -> do
          hPutStrLn System.IO.stderr stderr
          hPutStrLn System.IO.stderr stdout
          error . cs $ "command failed: " <> unwords (command : args)

data FlakeSpec = FlakeSpec
  { description :: Text,
    repo :: Maybe Text,
    prFromRepo :: Maybe Text,
    skipPrivateInputsCheck :: Maybe Bool,
    results :: [SubSpec]
  }
  deriving stock (Eq, Show, Generic)

strictOptions :: Options
strictOptions =
  defaultOptions
    { rejectUnknownFields = True
    }

instance FromJSON FlakeSpec where
  parseJSON = genericParseJSON strictOptions

data SubSpec = SubSpec
  { name :: Text,
    result :: Maybe Text,
    outputRegex :: Maybe Regex,
    outputLocation :: OutputLocation,
    index :: ResultIndex
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON SubSpec where
  parseJSON = genericParseJSON strictOptions

newtype Regex = Regex {getRegex :: R.Regex}
  deriving stock (Eq, Show, Generic)

instance FromJSON Regex where
  parseJSON = withText "Regex" $ \t -> case R.compileM (cs t) [] of
    Left e -> fail e
    Right v -> pure $ Regex v

data OutputLocation = Github | Website | Logs
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

data ResultIndex = First | Last | Nowhere | BeforeLast
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

base :: FilePath
base = "test/spec/Integration"

getTests :: IO [(FilePath, FlakeSpec)]
getTests = do
  contents <- listDirectory base
  dirs <- forM contents $ \c -> do
    let file = base </> c </> "spec.yaml"
    keep <- doesFileExist file
    if keep
      then do
        eFlakeSpec <- decodeFileEither file
        case eFlakeSpec of
          Left e -> error $ "Could not decode " <> cs file <> ": " <> show e
          Right flakeSpec -> pure $ Just (c, flakeSpec)
      else pure Nothing
  pure $ catMaybes dirs

testFlakeSpec :: FilePath -> FlakeSpec -> IO ()
testFlakeSpec dir fspec = do
  githubAppInstallationId <- getGithubAppInstallationId
  buildRef <- newIORef mempty
  withSystemTempDirectory "garnix-test" $ \tmp -> do
    Turtle.cptree (base </> dir) tmp
    withTestEnvironment tmp $ \baseEnv -> do
      ghInterface <-
        Deprecated.testGithubInterface tmp buildRef <&> \ghi ->
          ghi
            { _githubInterfaceGetAccessToken = \iAuth -> do
                mgr <- view #manager
                liftIO
                  $ GHA.obtainAccessToken mgr iAuth
                  >>= \case
                    Left e -> error $ show e
                    Right (GH.OAuth v) -> pure $ GhToken $ cs v
                    Right _ -> error "Unexpected auth token type",
              _githubInterfaceGetRepoCollaborators =
                _githubInterfaceGetRepoCollaborators realGithubInterface,
              _githubInterfaceGetRepoPublicity =
                _githubInterfaceGetRepoPublicity realGithubInterface
            }
      env <- do
        return
          $ baseEnv
          & (#githubInterface .~ ghInterface)
      run_ $ cmd "git" & silenceStdout & setWorkingDir tmp & addArgs ["init" :: String]
      run_ $ cmd "git" & silenceStdout & setWorkingDir tmp & addArgs ["add", "." :: String]
      run_ $ cmd "git" & silenceStdout & setWorkingDir tmp & addArgs ["commit", "-am", "Initial commit" :: String]
      commit <-
        CommitHash
          . cs
          . fromStdoutTrimmed
          <$> run (cmd "git" & setWorkingDir tmp & addArgs ["rev-parse", "HEAD" :: String])
      result <- runM env $ withDevSecrets $ suppressLogsWhenPassing $ do
        void $ DB.pgExec [pgSQL| TRUNCATE repo_config |]
        case (repo fspec, skipPrivateInputsCheck fspec) of
          (Just repository, Just True) ->
            let (repoUser, repoName) = parseRepo repository
             in void
                  $ DB.pgExec
                    [pgSQL|
              INSERT INTO repo_config
                (repo_user, repo_name, skip_private_inputs_check_for_collaborators)
                VALUES (${repoUser}, ${repoName}, TRUE)
            |]
          _ -> pure ()
        case prFromRepo fspec of
          Nothing -> do
            let event =
                  defaultEvent
                    & maybe identity (\repo -> eventRepoName .~ parseRepo repo) (repo fspec)
                    & installation
                    . _Just
                    . id
                    .~ githubAppInstallationId
                    & eventCommit
                    .~ commit
            notifyOfCommit event `catchError` const (pure ())
          Just fromRepo -> do
            toRepo <- case repo fspec of
              Nothing -> error "when using prFromRepo, please also specify repo"
              Just r -> pure r
            notifyOfPr commit "test-branch" fromRepo toRepo githubAppInstallationId
              `catchError` const (pure ())
        allBuilds <- readIORef buildRef
        testBuilds (join $ IntMap.elems allBuilds)
      cleanDbConn env
      case result of
        Right () -> pure ()
        Left err -> error $ showDebug err
  where
    testBuild :: Bool -> SubSpec -> (Text, RunReportStatus, RawLogs) -> M ()
    testBuild shouldFail ss (title, status, logs) = case outputLocation ss of
      Github -> do
        let status' = case status of
              RunReportStatusInProgress -> Nothing
              RunReportStatusSuccess -> Just "success"
              RunReportStatusFailure -> Just "failure"
              RunReportStatusTimeout -> Just "timeout"
              RunReportStatusCancelled -> Just "cancelled"
              RunReportStatusSkipped -> Just "skipped"
        let output =
              RunOutput
                { _runOutputTitle = title,
                  _runOutputSummary = "",
                  _runOutputText = processLogsForGithub logs
                }
        let succeed =
              when shouldFail
                $ liftIO
                $ expectationFailure
                $ cs
                $ "Got a match when expecting none. Run: "
                <> show output
            failWith msg = unless shouldFail $ liftIO $ expectationFailure msg
        liftIO $ status' `shouldBe` result ss
        case outputRegex ss of
          (Just (Regex re')) -> case R.match re' (cs $ output ^. text) [] of
            Nothing ->
              failWith
                $ "Regex did not match."
                <> "\nRegex:\n"
                <> cs (show re')
                <> "\nOutput:\n"
                <> cs (pShow output)
            Just [] ->
              failWith
                $ "Regex did not match."
                <> "\nRegex:\n"
                <> cs (show re')
                <> "\nOutput:\n"
                <> cs (pShow output)
            Just _ -> succeed
          Nothing -> succeed
      loc ->
        liftIO
          . expectationFailure
          . cs
          $ "Unexpected output location: "
          <> show loc

    testBuilds :: [(Text, RunReportStatus, RawLogs)] -> M ()
    testBuilds builds = forM_ (results fspec) $ \ss -> do
      case filter
        (\(title, _, _) -> name ss == title)
        builds of
        [] -> case index ss of
          Nowhere -> pure ()
          _ ->
            liftIO
              . expectationFailure
              . cs
              $ "Found an expectation that matches no build: "
              <> pShow ss
              <> "\nBuilds are: "
              <> pShow builds
        relevant -> do
          case index ss of
            -- The builds are in reverse order
            Last -> testBuild False ss $ head relevant
            BeforeLast -> testBuild False ss $ relevant !! 1
            First -> testBuild False ss $ last relevant
            Nowhere -> mapM_ (testBuild True ss) relevant

notifyOfPr :: CommitHash -> Branch -> Text -> Text -> Int -> M ()
notifyOfPr commit branch fromRepo toRepo id = do
  mFlakePromise <- do
    ghWebhookPullRequest $ mkPullRequestEvent commit branch fromRepo toRepo id
  resolve mFlakePromise
