{-# LANGUAGE OverloadedRecordDot #-}

module Garnix.Watchdog.Checks where

import Control.Concurrent (forkIO)
import Control.Concurrent.Async (forConcurrently_)
import Control.Exception.Safe (SomeException, catch, try)
import Control.Lens hiding (set, (<.>))
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except
import Cradle
import Data.Aeson (decode')
import qualified Data.List
import Data.Map (Map, insertWith, toAscList)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.String (fromString)
import Data.String.Conversions
import Data.Text as T
import Data.Text.IO as T
import Data.Time.Clock
import Garnix.Watchdog.Github
import Garnix.Watchdog.Utils
import Network.HTTP.Client (HttpException)
import Network.Wreq as Wreq hiding (get)
import System.Directory (copyFile, listDirectory)
import System.FilePath
import System.Metrics.Prometheus.Concurrent.Registry (Registry, registerCounter, registerGauge, registerHistogram)
import System.Metrics.Prometheus.Metric.Counter (inc)
import System.Metrics.Prometheus.Metric.Gauge (set)
import System.Metrics.Prometheus.Metric.Histogram (UpperBound, observe)
import System.Random (randomRIO)
import Prelude hiding (log)

data Check = Check
  { name :: CheckName,
    repeatInterval :: Duration,
    buckets :: [UpperBound],
    unsafeRunCheck :: CheckConfig -> IO CheckResult
  }

data CheckConfig = CheckConfig
  { dataDir :: FilePath,
    sshIdentityFile :: FilePath
  }

runCheck :: CheckConfig -> Check -> IO CheckResult
runCheck config check = do
  log check.name "running check"
  check.unsafeRunCheck config `catch` (pure . Exception)

runChecksAsMetrics :: CheckConfig -> Registry -> [Check] -> IO ()
runChecksAsMetrics config registry checks =
  forConcurrently_ checks $ \check -> do
    let checkName = cs $ getCheckName check.name
    errorCounter <-
      registerCounter
        (fromString $ "watchdog_" <> checkName <> "_error_total")
        mempty
        registry
    errorGauge <-
      registerGauge
        (fromString $ "watchdog_" <> checkName <> "_error_gauge")
        mempty
        registry
    latencyHistogram <-
      registerHistogram
        (fromString $ "watchdog_" <> checkName <> "_latency_seconds")
        mempty
        check.buckets
        registry
    latencyGauge <-
      registerGauge
        (fromString $ "watchdog_" <> checkName <> "_latency_gauge_seconds")
        mempty
        registry
    void $ forkIO $ forever $ do
      result <- runCheck config check
      case result of
        Success {latency = Duration seconds} -> do
          log check.name $ "succeeded in " <> cs (show seconds) <> " seconds"
          observe seconds latencyHistogram
          set seconds latencyGauge
          set 0 errorGauge
        Timeout {errorMessage} -> do
          log check.name $ "failed: " <> errorMessage
          inc errorCounter
          set 1 errorGauge
        Exception e -> do
          log check.name $ "crashed: " <> cs (show e)
          inc errorCounter
          set 1 errorGauge
      sleep $ repeatInterval check

data CheckResult
  = Success
      { latency :: Duration
      }
  | Timeout
      { errorMessage :: Text
      }
  | Exception
      { exception :: SomeException
      }
  deriving stock (Show)

waitFor :: CheckName -> Duration -> Duration -> ExceptT Text IO () -> IO CheckResult
waitFor checkName repeatInterval cutoff action = do
  start <- getCurrentTime
  go start
  where
    go start = do
      result <- runExceptT action
      case result of
        Right () -> do
          end <- getCurrentTime
          pure $
            Success
              { latency = diff start end
              }
        Left errorMessage -> do
          now <- getCurrentTime
          if diff start now >= cutoff
            then pure $ Timeout {errorMessage}
            else do
              log checkName $ "check not yet successful, will re-try... (" <> errorMessage <> ")"
              sleep repeatInterval
              go start

-- * checks

defaultChecks :: Map CheckName Check
defaultChecks = Map.fromList (fmap (\c -> (c.name, c)) [ciPushToCacheCheck, prDeploymentCheck, narDownloadCheck])

allChecks :: Map CheckName Check
allChecks = Map.insert testCheck.name testCheck defaultChecks

ciPushToCacheCheck :: Check
ciPushToCacheCheck =
  Check
    { name,
      repeatInterval = fromMinutes 5,
      -- 300 seconds (= 5 minutes) is our cutoff time
      buckets = [0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 300],
      unsafeRunCheck = \config -> do
        withRepo name config "ci" "ci-check" $ \repoDir -> do
          hashes <- forM systems $ \system -> do
            StdoutRaw output <-
              run $
                cmd "nix"
                  & addArgs
                    [ "eval",
                      ".#packages." <> system <> ".default",
                      "--apply",
                      "x : x.outPath",
                      "--json"
                    ]
                  & setWorkingDir repoDir
            let mHash =
                  decode' (cs output)
                    >>= stripPrefix "/nix/store/"
                    >>= stripSuffix "-package"
            pure
              ( system,
                fromMaybe
                  (error $ "cannot parse nix eval output: " <> cs (show output))
                  mHash
              )
          waitFor name (fromSeconds 1) (fromMinutes 10) $ do
            statusCodes <- forM hashes $ \(system, hash) -> do
              response <- getWithCacheToken ("https://cache.garnix.io/" <> cs hash <> ".narinfo")
              pure (system, response ^. responseStatus . statusCode)
            case Prelude.filter ((/= 200) . snd) statusCodes of
              [] -> pure ()
              errorResults -> throwE $ "expected status code: 200, got: " <> formatErrors errorResults
    }
  where
    name = CheckName "ci_push_to_cache"
    systems =
      [ "x86_64-linux",
        "aarch64-darwin",
        "aarch64-linux"
      ]
    formatErrors :: [(Text, Int)] -> Text
    formatErrors errors =
      errors
        & Data.List.foldl' (\acc (system, statusCode) -> insertWith (<>) statusCode [system] acc) mempty
        & toAscList
        & fmap (\(statusCode, systems) -> cs (show statusCode) <> " => " <> T.intercalate "," (Data.List.sort systems))
        & T.intercalate ", "

prDeploymentCheck :: Check
prDeploymentCheck =
  Check
    { name,
      repeatInterval = fromHour 1,
      -- 900 seconds (= 15 minutes) is our cutoff time
      buckets = [0.5, 1, 2, 3, 6, 12, 25, 50, 100, 200, 400, 900],
      unsafeRunCheck = \config -> do
        withRepo name config "pr-deployment" "test-pr-1" $ \repoDir -> do
          date <- T.readFile (repoDir </> "date")
          waitFor name (fromSeconds 5) (fromMinutes 15) $ do
            response <- get "http://watchdog-pr-deployment-server.pull-2.watchdog-test-repo.garnix-watchdog.garnix.me"
            when (response ^. responseStatus . statusCode /= 200) $ do
              throwE $ "expected: 200, got: " <> cs (show (response ^. responseStatus . statusCode))
            when (cs (response ^. responseBody) /= date) $ do
              throwE $ "expected: " <> cs (show date) <> ", got: " <> cs (show (response ^. responseBody))
    }
  where
    name = CheckName "pr_deployments_push"

testCheck :: Check
testCheck =
  Check
    { name,
      repeatInterval = fromSeconds 15,
      buckets = [0.01, 0.1, 0.5, 1, 2, 4, 6, 10, 30, 60, 120, 600],
      unsafeRunCheck = const $ waitFor name (fromSeconds 1) (fromSeconds 10) $ do
        sleep $ fromSeconds 0.5
        succeeded <- randomRIO (0, 1 :: Double)
        if succeeded < 0.2
          then pure ()
          else throwE "failed :("
    }
  where
    name = CheckName "test_check"

narDownloadCheck :: Check
narDownloadCheck =
  Check
    { name,
      repeatInterval = fromMinutes 5,
      buckets = [0.5, 0.8, 1, 2, 3, 5, 10, 20, 60, 120],
      unsafeRunCheck = \_ -> do
        waitFor name (fromSeconds 10) (fromMinutes 2) $ do
          response <- assert200 getWithCacheToken ("https://cache.garnix.io/" <> hash <.> "narinfo")
          narUrl <- case mapMaybe (T.stripPrefix "URL: ") (T.lines (cs response)) of
            [url] -> pure url
            [] -> throwE "`URL:` not found in narinfo file"
            _ -> throwE "multiple `URL:`s found in narinfo file"
          _ <- assert200 (getWithOptions id) (cs narUrl)
          pure ()
    }
  where
    name = CheckName "nar_download"
    hash = "szbqkcf023gc61w7pzllngp0f3llr4b4"
    assert200 :: (String -> ExceptT Text IO (Response body)) -> String -> ExceptT Text IO body
    assert200 getter url = do
      response <- getter url
      when (response ^. responseStatus . statusCode /= 200) $ do
        throwE $ "expected: 200, got: " <> cs (show (response ^. responseStatus . statusCode)) <> " (" <> cs url <> ")"
      pure $ response ^. responseBody

-- * check helpers

withRepo :: CheckName -> CheckConfig -> FilePath -> Text -> (FilePath -> IO a) -> IO a
withRepo checkName config name branch action = do
  let templateDir = config.dataDir </> name
  withTestRepo checkName config.sshIdentityFile $ \repo -> do
    testFiles <- listDirectory templateDir
    forM_ testFiles $ \f -> do
      copyFile (templateDir </> f) (repoDir repo </> f)
    run_ $ cmd "chmod" & addArgs ["u+rwX", "-R", repoDir repo]
    StdoutTrimmed date <- run $ cmd "date" & addArgs ["--iso-8601=seconds", "--utc" :: String]
    T.writeFile (repoDir repo </> "date") date
    let commitMessage = "test commit (" <> date <> ")"
    pushTestRepo checkName repo commitMessage branch
    log checkName $ "pushed " <> commitMessage
    action repo.repoDir

getWithOptions :: (Options -> Options) -> String -> ExceptT Text IO (Response LBS)
getWithOptions modifyOpts url = do
  let options = Wreq.defaults & checkResponse ?~ (\_request _response -> pure ()) & modifyOpts
  response <- liftIO $ try $ Wreq.getWith options url
  case response of
    Left (exception :: HttpException) -> throwE $ cs $ show exception
    Right response -> pure response

getWithCacheToken :: String -> ExceptT Text IO (Response LBS)
getWithCacheToken = getWithOptions $ auth ?~ basicAuth "garnix-watchdog" "5yMWz8w700PvZHpe2IEz9xspxYFEyCz88tH7I2n8"

get :: String -> ExceptT Text IO (Response LBS)
get = getWithOptions id
