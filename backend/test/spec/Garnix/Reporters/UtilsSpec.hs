module Garnix.Reporters.UtilsSpec where

import Control.Exception.Lifted (ErrorCall (..), throwIO)
import Control.Lens
import Cradle
import Data.Map.Strict ((!))
import Data.Text qualified as T
import Garnix.BuildLogs.Types (mkLogLine)
import Garnix.DB qualified as DB
import Garnix.Monad
import Garnix.Prelude
import Garnix.Reporters.Utils
import Garnix.TestHelpers (defaultCommitInfo)
import Garnix.TestHelpers.Monad
import Garnix.TestHelpers.Reporter (TestReport (..), withTestReporter, withTestReporter_)
import Garnix.Types
import Test.Hspec

spec :: Spec
spec = inM $ do
  describe "withRunReporter" $ do
    it "creates a RunReporter" $ do
      report <- withTestReporter_ $ \reporter -> do
        run <- DB.newRun "test name" defaultCommitInfo
        withRunReporter reporter (ReportRun run) $ \runReporter -> do
          reportLogs runReporter (mkLogLine "test log")
          reportComplete runReporter RunReportStatusSuccess
      (report ! "test name") `shouldBeM` TestReport "test log" (Just True)

    it "catches monadic errors and reports them" $ do
      report <- withTestReporter_ $ \reporter -> do
        run <- DB.newRun "test name" defaultCommitInfo
        void $ tryEither $ withRunReporter reporter (ReportRun run) $ \_runReporter ->
          throw $ OtherError "test error"
      liftIO $ cs (report ^?! ix "test name" . #logs) `shouldContain` "test error"
      (report ^?! ix "test name" . #success) `shouldBeM` Just False

    it "catches runtime exceptions and reports them" $ do
      report <- withTestReporter_ $ \reporter -> do
        run <- DB.newRun "test name" defaultCommitInfo
        void $ tryEither $ withRunReporter reporter (ReportRun run) $ \_runReporter ->
          throwIO $ ErrorCall "test error"
      (report ! "test name") `shouldBeM` TestReport "test error" (Just False)

  describe "reporter semigroup" $ do
    it "logs to both given reporters" $ do
      (reportA, reportB) <- withTestReporter $ \a -> do
        withTestReporter_ $ \b -> do
          run <- DB.newRun "test run" defaultCommitInfo
          runReporter <- createNewRun (a <> b) (ReportRun run)
          reportLogs runReporter (mkLogLine "test log")
      reportA ! "test run" `shouldBeM` TestReport "test log" Nothing
      reportB ! "test run" `shouldBeM` TestReport "test log" Nothing

    it "sends final reports to both given reporters" $ do
      (reportA, reportB) <- withTestReporter $ \a -> do
        withTestReporter_ $ \b -> do
          run <- DB.newRun "test run" defaultCommitInfo
          runReporter <- createNewRun (a <> b) (ReportRun run)
          reportLogs runReporter (mkLogLine "test log")
          reportComplete runReporter RunReportStatusSuccess
      reportA ! "test run" `shouldBeM` TestReport "test log" (Just True)
      reportB ! "test run" `shouldBeM` TestReport "test log" (Just True)

  describe "runWithRunReporter" $ do
    it "sends stdout of the child process to the `RunReporter`" $ do
      report <- withTestReporter_ $ \reporter -> do
        run <- DB.newRun "test name" defaultCommitInfo
        withRunReporter reporter (ReportRun run) $ \runReporter -> do
          runWithRunReporter_ runReporter $ cmd "echo"
            & addArgs ["foo" :: Text]
      report ^? ix "test name" `shouldBeM` Just (TestReport "foo" Nothing)

    it "sends stderr of the child process to the `RunReporter`" $ do
      report <- withTestReporter_ $ \reporter -> do
        run <- DB.newRun "test name" defaultCommitInfo
        withRunReporter reporter (ReportRun run) $ \runReporter -> do
          runWithRunReporter_ runReporter $ cmd "bash"
            & addArgs ["-c", "echo foo >&2" :: Text]
      report ^? ix "test name" `shouldBeM` Just (TestReport "foo" Nothing)

    it "sends interleaved stdout and stderr to the `RunReporter`" $ do
      report <- withTestReporter_ $ \reporter -> do
        run <- DB.newRun "test name" defaultCommitInfo
        withRunReporter reporter (ReportRun run) $ \runReporter -> do
          runWithRunReporter_ runReporter $ cmd "bash"
            & addArgs ["-c", T.unlines ["echo foo >&2", "sleep 0.1", "echo bar", "sleep 0.1", "echo baz >&2"]]
      report ^? ix "test name" `shouldBeM` Just (TestReport "foo\nbar\nbaz" Nothing)

    it "sends `stdout` and `stderr`, even when captured in cradle output" $ do
      report <- withTestReporter_ $ \reporter -> do
        run <- DB.newRun "test name" defaultCommitInfo
        withRunReporter reporter (ReportRun run) $ \runReporter -> do
          (StdoutRaw _, StderrRaw _) <-
            runWithRunReporter runReporter $ cmd "bash"
              & addArgs ["-c", T.unlines ["echo foo", "sleep 0.1", "echo bar >&2"]]
          pure ()
      report ^? ix "test name" `shouldBeM` Just (TestReport "foo\nbar" Nothing)

    it "doesn't introduce newlines between chunks" $ do
      report <- withTestReporter_ $ \reporter -> do
        run <- DB.newRun "test name" defaultCommitInfo
        withRunReporter reporter (ReportRun run) $ \runReporter -> do
          (StdoutRaw _, StderrRaw _) <-
            runWithRunReporter runReporter $ cmd "bash"
              & addArgs ["-c", T.unlines ["stdbuf -o0 printf foo", "sleep 0.1", "echo bar"]]
          pure ()
      report ^? ix "test name" `shouldBeM` Just (TestReport "foobar" Nothing)
