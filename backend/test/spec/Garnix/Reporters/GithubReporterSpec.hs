module Garnix.Reporters.GithubReporterSpec where

import Control.Concurrent.Async.Lifted (asyncThreadId, wait, withAsync)
import Control.Concurrent.Lifted (newEmptyMVar, putMVar, readMVar, tryReadMVar)
import Control.Lens
import Data.IORef.Lifted (modifyIORef, newIORef, readIORef)
import Data.Text qualified as T
import GHC.Conc (ThreadStatus (..), threadStatus)
import Garnix.BuildLogs.Types (mkLogLine)
import Garnix.DB qualified as DB
import Garnix.Duration
import Garnix.Monad
import Garnix.Prelude
import Garnix.Reporters.GithubReporter
import Garnix.TestHelpers (defaultCommitInfo, waitFor)
import Garnix.TestHelpers.GithubInterface qualified as GH
import Garnix.TestHelpers.Monad
import Garnix.Types
import Test.Hspec

spec :: Spec
spec = do
  let testDebounceDuration = fromMilliSeconds @Int 5
  inM $ aroundM_ (local (#githubLogDebounceDuration .~ testDebounceDuration)) $ describe "mkGithubReporter" $ do
    it "reports successful runs to github" $ GH.withFakeGithubInterface $ \ghState -> do
      GH.mkRepo ghState "owner" "repo" identity
      let reporter = mkGithubReporter (RepoInfo ForgeGithub Nothing undefined "owner" "repo") "abc"
      run <- DB.newRun "name" defaultCommitInfo
      runReporter <- createNewRun reporter (ReportRun run)
      reportLogs runReporter (mkLogLine "some log line")
      reportComplete runReporter RunReportStatusSuccess
      reports <- fromReports <$> GH.getReports ghState
      reports `shouldBeM` [("name", RunReportStatusInProgress, ""), ("name", RunReportStatusSuccess, "some log line\n")]

    it "reports failing runs to github" $ GH.withFakeGithubInterface $ \ghState -> do
      GH.mkRepo ghState "owner" "repo" identity
      let reporter = mkGithubReporter (RepoInfo ForgeGithub Nothing undefined "owner" "repo") "abc"
      run <- DB.newRun "name" defaultCommitInfo
      runReporter <- createNewRun reporter (ReportRun run)
      reportLogs runReporter (mkLogLine "some log line")
      reportComplete runReporter RunReportStatusFailure
      reports <- fromReports <$> GH.getReports ghState
      reports `shouldBeM` [("name", RunReportStatusInProgress, ""), ("name", RunReportStatusFailure, "some log line\n")]

    it "retries an identical completion after an update failed" $ GH.withFakeGithubInterface $ \ghState -> do
      GH.mkRepo ghState "owner" "repo" identity
      let reporter = mkGithubReporter (RepoInfo ForgeGithub Nothing undefined "owner" "repo") "abc"
      run <- DB.newRun "name" defaultCommitInfo
      runReporter <- createNewRun reporter (ReportRun run)
      attempts <- newIORef (0 :: Int)
      github <- view #githubInterface
      let flakyGithub =
            github
              { _githubInterfaceUpdateBuildReport = \runId report repo -> do
                  modifyIORef attempts succ
                  n <- readIORef attempts
                  if n == 1
                    then throw $ OtherError "temporary GitHub failure"
                    else _githubInterfaceUpdateBuildReport github runId report repo
              }
      local (#githubInterface .~ flakyGithub)
        $ reportComplete runReporter RunReportStatusSuccess
      readIORef attempts `shouldReturnM` 2
      reports <- fromReports <$> GH.getReports ghState
      reports `shouldBeM` [("name", RunReportStatusInProgress, ""), ("name", RunReportStatusSuccess, "")]

    it "does not suppress an identical completion after retries are exhausted" $ local (#githubLogDebounceDuration .~ emptyDuration) $ GH.withFakeGithubInterface $ \ghState -> do
      GH.mkRepo ghState "owner" "repo" identity
      let reporter = mkGithubReporter (RepoInfo ForgeGithub Nothing undefined "owner" "repo") "abc"
      run <- DB.newRun "name" defaultCommitInfo
      runReporter <- createNewRun reporter (ReportRun run)
      github <- view #githubInterface
      reportLogs runReporter (mkLogLine "some log line")
      let failingGithub =
            github
              { _githubInterfaceUpdateBuildReport = \_ _ _ -> throw $ OtherError "GitHub unavailable"
              }
      local (#githubInterface .~ failingGithub)
        $ reportComplete runReporter RunReportStatusSuccess
      reportComplete runReporter RunReportStatusSuccess
      reports <- fromReports <$> GH.getReports ghState
      reports
        `shouldBeM` [ ("name", RunReportStatusInProgress, ""),
                      ("name", RunReportStatusInProgress, "some log line\n"),
                      ("name", RunReportStatusSuccess, "some log line\n")
                    ]

    it "serializes log updates with completion so an older request cannot overwrite it"
      $ local (#githubLogDebounceDuration .~ emptyDuration)
      $ shouldTerminate (fromSeconds @Int 5)
      $ GH.withFakeGithubInterface
      $ \ghState -> do
        GH.mkRepo ghState "owner" "repo" identity
        let reporter = mkGithubReporter (RepoInfo ForgeGithub Nothing undefined "owner" "repo") "abc"
        run <- DB.newRun "name" defaultCommitInfo
        runReporter <- createNewRun reporter (ReportRun run)
        firstStarted <- newEmptyMVar
        secondStarted <- newEmptyMVar
        releaseFirst <- newEmptyMVar
        releaseSecond <- newEmptyMVar
        github <- view #githubInterface
        let gatedGithub =
              github
                { _githubInterfaceUpdateBuildReport = \runId report repo -> do
                    if report ^. status == RunReportStatusInProgress
                      then putMVar firstStarted () >> readMVar releaseFirst
                      else putMVar secondStarted () >> readMVar releaseSecond
                    _githubInterfaceUpdateBuildReport github runId report repo
                }
        overlapping <- local (#githubInterface .~ gatedGithub)
          $ withAsync (reportLogs runReporter (mkLogLine "some log line"))
          $ \first -> do
            readMVar firstStarted
            withAsync (reportComplete runReporter RunReportStatusSuccess) $ \second -> do
              -- With the fix, completion blocks on the sender mutex. Without
              -- it, the second API call reaches its own gate. Neither can
              -- finish until released, so no scheduling delay is assumed.
              waitFor (fromSeconds @Int 5) $ do
                state <- liftIO $ threadStatus $ asyncThreadId second
                state `shouldSatisfyM` \case
                  ThreadBlocked _ -> True
                  ThreadFinished -> True
                  ThreadDied -> True
                  ThreadRunning -> False
              overlapping <- isJust <$> tryReadMVar secondStarted
              putMVar releaseFirst ()
              putMVar releaseSecond ()
              wait first
              wait second
              pure overlapping
        overlapping `shouldBeM` False
        reports <- fromReports <$> GH.getReports ghState
        reports ^? _last `shouldBeM` Just ("name", RunReportStatusSuccess, "some log line\n")

    describe "reportLogs" $ do
      it "reports log lines without final status to github" $ GH.withFakeGithubInterface $ \ghState -> do
        GH.mkRepo ghState "owner" "repo" identity
        let reporter = mkGithubReporter (RepoInfo ForgeGithub Nothing undefined "owner" "repo") "abc"
        run <- DB.newRun "name" defaultCommitInfo
        runReporter <- createNewRun reporter (ReportRun run)
        reportLogs runReporter (mkLogLine "some log line")
        threadDelay (testDebounceDuration `multiplyDuration` (2 :: Int))
        reports <- fromReports <$> GH.getReports ghState
        reports `shouldBeM` [("name", RunReportStatusInProgress, ""), ("name", RunReportStatusInProgress, "some log line\n")]

      it "doesn't modify the current status" $ GH.withFakeGithubInterface $ \ghState -> do
        GH.mkRepo ghState "owner" "repo" identity
        let reporter = mkGithubReporter (RepoInfo ForgeGithub Nothing undefined "owner" "repo") "abc"
        run <- DB.newRun "name" defaultCommitInfo
        runReporter <- createNewRun reporter (ReportRun run)
        reportLogs runReporter (mkLogLine "foo")
        threadDelay (testDebounceDuration `multiplyDuration` (2 :: Int))
        reportComplete runReporter RunReportStatusSuccess
        reportLogs runReporter (mkLogLine "bar")
        threadDelay (testDebounceDuration `multiplyDuration` (2 :: Int))
        reports <- fromReports <$> GH.getReports ghState
        reports
          `shouldBeM` [ ("name", RunReportStatusInProgress, ""),
                        ("name", RunReportStatusInProgress, "foo\n"),
                        ("name", RunReportStatusSuccess, "foo\n"),
                        ("name", RunReportStatusSuccess, "foo\nbar\n")
                      ]

      it "debounces requests to github" $ GH.withFakeGithubInterface $ \ghState -> do
        local (#githubLogDebounceDuration .~ fromMilliSeconds @Int 100) $ do
          GH.mkRepo ghState "owner" "repo" identity
          let reporter = mkGithubReporter (RepoInfo ForgeGithub Nothing undefined "owner" "repo") "abc"
          run <- DB.newRun "name" defaultCommitInfo
          runReporter <- createNewRun reporter (ReportRun run)
          replicateM_ 10 $ do
            reportLogs runReporter (mkLogLine "x")
          reports <- waitFor (fromSeconds @Int 5) $ do
            reports <- fromReports <$> GH.getReports ghState
            reports
              ^? _last
                `shouldBeM` Just ("name", RunReportStatusInProgress, T.unlines $ replicate 10 "x")
            pure reports
          length reports `shouldSatisfyM` (< 11)

      it "sends the last update immediately" $ GH.withFakeGithubInterface $ \ghState -> do
        local (#githubLogDebounceDuration .~ fromSeconds @Int 5) $ do
          GH.mkRepo ghState "owner" "repo" identity
          let reporter = mkGithubReporter (RepoInfo ForgeGithub Nothing undefined "owner" "repo") "abc"
          run <- DB.newRun "name" defaultCommitInfo
          runReporter <- createNewRun reporter (ReportRun run)
          replicateM_ 10 $ do
            reportLogs runReporter (mkLogLine "x")
          reportLogs runReporter (mkLogLine "final")
          reportComplete runReporter RunReportStatusSuccess
          reports <- fromReports <$> GH.getReports ghState
          reports
            `shouldBeM` [ ("name", RunReportStatusInProgress, ""),
                          ("name", RunReportStatusSuccess, T.unlines (replicate 10 "x" <> ["final"]))
                        ]

fromReports :: [[(RepoInfo, GhRunReport)]] -> [(Text, RunReportStatus, Text)]
fromReports reports = map go $ concat reports
  where
    go :: (RepoInfo, GhRunReport) -> (Text, RunReportStatus, Text)
    go (_, report) = (report ^. name, report ^. status, getRawLogs (report ^. logs))
