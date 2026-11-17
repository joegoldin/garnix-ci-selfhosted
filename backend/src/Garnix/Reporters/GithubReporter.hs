module Garnix.Reporters.GithubReporter (mkGithubReporter) where

import Control.Concurrent.Lifted (modifyMVar_, newMVar, readMVar)
import Control.Debounce
import Control.Retry (exponentialBackoff, limitRetries)
import Data.Text qualified as T
import Garnix.BuildLogs.Types (LogLine (..))
import Garnix.DB qualified as DB
import Garnix.Duration
import Garnix.Monad
import Garnix.Prelude
import Garnix.Request (retryingWithPolicy)
import Garnix.Types
import Network.URI (URI, parseRelativeReference)

mkGithubReporter :: RepoInfo -> CommitHash -> Reporter
mkGithubReporter repoInfo commit =
  Reporter
    { createNewRun = \reportType -> do
        let name = reportName reportType
        url <- getRelativeUrl reportType
        let initialReport = mkReport name url commit "" RunReportStatusInProgress
        existingRunId <- case reportType of
          ReportBuild _ build -> pure $ build ^. githubRunId
          ReportRun run -> DB.getRunGithubRunId (run ^. id)
          MetaCheck -> pure Nothing
        ghRunId <- case existingRunId of
          Just runId -> pure runId
          Nothing -> do
            runId <- newBuildReport repoInfo initialReport
            case reportType of
              ReportRun run -> DB.setRunGithubRunId (run ^. id) runId
              _ -> pure ()
            pure runId
        logsMVar <- newMVar (RunReportStatusInProgress, Nothing)
        lastSentLogsMVar <- newMVar Nothing
        let addNewline t = if "\n" `T.isSuffixOf` t then t else t <> "\n"
        let appendLogs status logs = do
              modifyMVar_ logsMVar $ \(curStatus, curLogs) -> do
                pure (fromMaybe curStatus status, Just $ mconcat $ map addNewline $ catMaybes [curLogs, logs])
        -- Serialize snapshots and sends so an in-flight log update cannot
        -- overwrite completion. Failed sends must leave the last success intact.
        let sendLogs = ignoringAllErrors
              $ modifyMVar_ lastSentLogsMVar
              $ \lastSent -> do
                (status, logs) <- readMVar logsMVar
                if lastSent == Just (status, logs)
                  then pure lastSent
                  else do
                    let report = mkReport name url commit (fromMaybe "" logs) status
                        policy = limitRetries 2 <> exponentialBackoff (toMicroseconds $ fromSeconds @Int 1)
                    retryingWithPolicy policy $ updateBuildReport ghRunId report repoInfo
                    pure $ Just (status, logs)
        debouncedSendLogs <- do
          debounceDuration <- view #githubLogDebounceDuration
          if debounceDuration == emptyDuration
            then pure sendLogs
            else do
              env <- ask
              liftIO
                <$> liftIO
                  ( mkDebounce
                      defaultDebounceSettings
                        { debounceAction = void $ runM env sendLogs,
                          debounceFreq = toMicroseconds debounceDuration,
                          debounceEdge = trailingEdge
                        }
                  )
        pure
          $ RunReporter
            { reportLogs = \(LogLine package _phase log) -> do
                appendLogs Nothing $ Just $ prefixLogLineWithPackageName package log
                debouncedSendLogs,
              reportComplete = \status -> do
                appendLogs (Just status) Nothing
                sendLogs,
              ghRunId = Just ghRunId
            }
    }

prefixLogLineWithPackageName :: Maybe PackageName -> Text -> Text
prefixLogLineWithPackageName mPkgName logLine = prefix <> logLine
  where
    prefix = maybe "" ((<> "> ") . getPackageName) mPkgName

getRelativeUrl :: ReportType -> M (Maybe URI)
getRelativeUrl buildOrRun = do
  let path = case buildOrRun of
        ReportBuild _name build -> Just $ "/build/" <> build ^. id . to getBuildId . re hashIdText
        ReportRun run -> Just $ "/run/" <> run ^. id . to getRunId . re hashIdText
        MetaCheck -> Nothing
  case path of
    Nothing -> pure Nothing
    Just path -> do
      case parseRelativeReference (cs path) of
        Just uri -> pure $ Just uri
        Nothing -> throw $ OtherError $ "Failed to parse build URI from " <> path

mkReport :: Text -> Maybe URI -> CommitHash -> Text -> RunReportStatus -> GhRunReport
mkReport name url commit logs reportStatus =
  GhRunReport
    { _ghRunReportName = name,
      _ghRunReportCommit = commit,
      _ghRunReportUrl = show <$> url,
      _ghRunReportStatus = reportStatus,
      _ghRunReportTitle = name,
      _ghRunReportSummary = getReportSummary $ checkRunSummary name reportStatus,
      _ghRunReportLogs = RawLogs logs
    }

checkRunSummary :: Text -> RunReportStatus -> ReportSummary
checkRunSummary runName = \case
  RunReportStatusInProgress -> ReportSummary runName
  RunReportStatusSuccess -> ReportSummary $ runName <> " succeeded"
  RunReportStatusFailure -> ReportSummary $ runName <> " failed"
  RunReportStatusTimeout -> ReportSummary $ runName <> " timed out"
  RunReportStatusCancelled -> ReportSummary $ runName <> " cancelled"
  RunReportStatusSkipped -> ReportSummary $ runName <> " skipped"
