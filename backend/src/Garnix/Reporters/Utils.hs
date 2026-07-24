module Garnix.Reporters.Utils
  ( withRunReporter,
    runWithRunReporter,
    runWithRunReporterNoStdout,
    runWithRunReporter_,
  )
where

import Control.Concurrent.Async.Lifted qualified as Async
import Cradle qualified
import Cradle.ProcessConfiguration (ProcessConfiguration (..), addHandle)
import Data.Function (applyWhen)
import Data.IORef (atomicModifyIORef', newIORef)
import Garnix.BuildLogs.Types (mkLogLine)
import Garnix.DB qualified as DB
import Garnix.Monad
import Garnix.Prelude
import Garnix.SafeUnix (safeCreatePipe)
import Garnix.Types
import Streaming.ByteString.Char8 qualified as S
import Streaming.Prelude qualified as S hiding (fromHandle)
import System.IO qualified

withRunReporter :: Reporter -> ReportType -> (RunReporter -> M a) -> M a
withRunReporter report reportType action = do
  runReporter' <- createNewRun report reportType
  -- Every run kind (actions, FOD checks, module publish, deployments) stays
  -- "pending" until its first line of output, like builds do (see
  -- markRunningOnFirstLog in Garnix.Build.Reporting).
  runReporter <- case reportType of
    ReportRun run -> do
      pendingRef <- liftIO $ newIORef True
      pure
        runReporter'
          { reportLogs = \logLine -> do
              isFirst <- liftIO $ atomicModifyIORef' pendingRef (False,)
              when isFirst $ DB.markRunRunning (_runId run)
              -- Surface the run's current step inline in the commit WAITING-ON
              -- tree (empty lines are ignored, keeping the last real phase).
              setRunPhase (_runId run) (phaseFromLogLine logLine)
              reportLogs runReporter' logLine,
            reportComplete = \status -> do
              clearRunPhase (_runId run)
              reportComplete runReporter' status
          }
    _ -> pure runReporter'
  -- Never leak a run's tracked phase, whether it finishes normally, via
  -- reportComplete, or by throwing.
  let cleanup = case reportType of
        ReportRun run -> clearRunPhase (_runId run)
        _ -> pure ()
  flip finally cleanup $ catchEither (action runReporter) $ \e -> do
    let message = case e of
          Right e -> show $ pretty $ err e
          Left e -> show e
    reportLogs runReporter (mkLogLine message)
    reportComplete runReporter RunReportStatusFailure
    rethrowEither e

-- | Sends both `stdout` and `stderr` to the given `RunReporter`. Also disables
-- sending the `stdout` and `stderr` to the parent's output streams.
runWithRunReporter :: (Cradle.Output o) => RunReporter -> Cradle.ProcessConfiguration -> M o
runWithRunReporter = runWithRunReporter' True

runWithRunReporterNoStdout :: (Cradle.Output o) => RunReporter -> Cradle.ProcessConfiguration -> M o
runWithRunReporterNoStdout = runWithRunReporter' False

runWithRunReporter' :: (Cradle.Output o) => Bool -> RunReporter -> Cradle.ProcessConfiguration -> M o
runWithRunReporter' sendStdout runReporter config = do
  (readHandle, writeHandle) <- liftIO safeCreatePipe
  let pipeThread = do
        let lines = S.mapped S.toLazy $ S.lines $ S.fromHandle readHandle
        flip S.mapM_ lines $ \line -> do
          reportLogs runReporter (mkLogLine $ cs line)
  Async.withAsync pipeThread $ \pipeThread -> do
    output <-
      Cradle.run
        $ applyWhen
          sendStdout
          (\c -> c {stdoutConfig = Cradle.ProcessConfiguration.addHandle writeHandle (stdoutConfig config)})
        $ config {stderrConfig = Cradle.ProcessConfiguration.addHandle writeHandle (stderrConfig config)}
    liftIO $ System.IO.hClose writeHandle
    Async.wait pipeThread
    pure output

runWithRunReporter_ :: RunReporter -> Cradle.ProcessConfiguration -> M ()
runWithRunReporter_ runReporter cmd = runWithRunReporter runReporter cmd
