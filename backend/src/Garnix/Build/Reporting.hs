module Garnix.Build.Reporting
  ( reportOnError,
    reportBuildResult,
    reportBuildCancelledToForge,
    reportRunCancelledToForge,
    reportNameForBuild,
    markRunningOnFirstLog,
  )
where

import Control.Lens
import Data.IORef (atomicModifyIORef', newIORef)
import Garnix.BuildLogs.Types (mkLogLine)
import Garnix.DB qualified as DB
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types as Types

-- | Wrap a build's reporter so the build is marked "running"
-- (@run_started_at@ is set) on its first line of output, staying "pending"
-- until then. Without this a build flips to "running" the instant it is
-- scheduled — showing everything green while it is still only evaluating with
-- no output yet.
markRunningOnFirstLog :: Build -> RunReporter -> M RunReporter
markRunningOnFirstLog build runReporter = do
  pendingRef <- liftIO $ newIORef True
  pure
    runReporter
      { reportLogs = \logLine -> do
          isFirst <- liftIO $ atomicModifyIORef' pendingRef (False,)
          when isFirst $ DB.markBuildRunning (build ^. id)
          reportLogs runReporter logLine
      }

reportNameForBuild :: Build -> Text
reportNameForBuild build =
  let isBuildStarting = (build ^. package) == buildStarting
      sysBrackets = case build ^. system of
        NoSystem -> ""
        IsSystem sys -> " [" <> sys ^. systemTextIso <> "]"
   in if isBuildStarting
        then "Evaluate flake.nix"
        else case build ^. packageType of
          TypeOverall -> "Evaluate flake.nix"
          TypeDevShell ->
            "devShell " <> cs (build ^. package) <> sysBrackets
          TypePackage ->
            "package " <> cs (build ^. package) <> sysBrackets
          TypeCheck ->
            "check " <> cs (build ^. package) <> sysBrackets
          TypeHomeConfiguration -> "homeConfig " <> cs (build ^. package)
          TypeDarwinConfiguration -> "darwinConfig " <> cs (build ^. package)
          TypeNixosConfiguration -> "nixosConfig " <> cs (build ^. package)
          TypeDefaultPackage -> "default package" <> sysBrackets
          TypeDefaultDevShell -> "default devShell" <> sysBrackets
          TypeApp -> "app " <> cs (build ^. package)

reportBuildResult :: RunReporter -> Build -> M ()
reportBuildResult runReporter build = do
  DB.reportBuildResultDB build
  let status' = case build ^. status of
        Nothing -> RunReportStatusInProgress
        Just Success -> RunReportStatusSuccess
        Just Failure -> RunReportStatusFailure
        Just Timeout -> RunReportStatusTimeout
        Just Cancelled -> RunReportStatusCancelled
        Just Skipped -> RunReportStatusSkipped
  ignoringAllErrors $ reportComplete runReporter status'

-- | Best-effort: push a terminal @Cancelled@ status to the forge for a build
-- whose DB row a cancel endpoint has already updated. Unlike
-- 'reportBuildResult' this does NOT touch the DB (the cancel site is the
-- authoritative writer); it only opens a fresh check-run / commit-status and
-- immediately completes it as cancelled, forge-dispatched via the given
-- reporter. Swallows all forge errors so a forge outage never 500s the cancel
-- endpoint.
reportBuildCancelledToForge :: Reporter -> Build -> M ()
reportBuildCancelledToForge reporter build =
  ignoringAllErrors $ do
    runReporter <- createNewRun reporter (ReportBuild (reportNameForBuild build) build)
    reportComplete runReporter RunReportStatusCancelled

-- | Best-effort: push a terminal @Cancelled@ status to the forge for a run
-- (action / FOD check / deployment) whose DB row a cancel endpoint has already
-- updated. See 'reportBuildCancelledToForge'.
reportRunCancelledToForge :: Reporter -> Run -> M ()
reportRunCancelledToForge reporter run =
  ignoringAllErrors $ do
    runReporter <- createNewRun reporter (ReportRun run)
    reportComplete runReporter RunReportStatusCancelled

reportOnError :: RunReporter -> Build -> CommitInfo -> M a -> M a
reportOnError runReporter build commitInfo io = do
  io `whenError` \e -> do
    DB.setCommitStatus (commitInfo ^. repoInfo . ghRepoOwner) (commitInfo ^. repoInfo . ghRepoName) (commitInfo ^. commit) Evaluated
    reportLogs runReporter $ mkLogLine $ showPretty (err e)
    reportBuildResult runReporter $ build
      & status ?~ Failure
