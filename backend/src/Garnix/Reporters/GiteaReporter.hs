-- | Build-status reporter for Gitea repos. Gitea has no check-runs API, so we
-- use commit statuses (@POST /repos/{owner}/{repo}/statuses/{sha}@): one
-- "pending" status when a run starts, one terminal status when it completes.
-- Statuses cannot carry logs, so 'reportLogs' is a no-op — the garnix web UI
-- (linked via @target_url@) is where logs live.
module Garnix.Reporters.GiteaReporter (mkGiteaReporter) where

import Garnix.GiteaInterface
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import Network.URI (URI, parseRelativeReference)

mkGiteaReporter :: GiteaConfig -> RepoInfo -> CommitHash -> Reporter
mkGiteaReporter cfg repoInfo commit =
  Reporter
    { createNewRun = \reportType -> do
        let name = reportName reportType
        url <- getAbsoluteUrl reportType
        let postStatus state description =
              ignoringAllErrors
                $ giteaPostCommitStatus
                  cfg
                  (repoInfo ^. ghRepoOwner)
                  (repoInfo ^. ghRepoName)
                  commit
                  GiteaCommitStatus
                    { giteaStatusState = state,
                      giteaStatusTargetUrl = fromMaybe "" url,
                      giteaStatusDescription = description,
                      giteaStatusContext = "garnix/" <> name
                    }
        postStatus GiteaPending name
        pure
          $ RunReporter
            { reportLogs = \_ -> pure (), -- statuses can't carry logs; see module docs
              reportComplete = \status ->
                postStatus (toGiteaState status) (name <> " " <> statusPhrase status),
              ghRunId = Nothing
            }
    }

toGiteaState :: RunReportStatus -> GiteaStatusState
toGiteaState = \case
  RunReportStatusInProgress -> GiteaPending
  RunReportStatusSuccess -> GiteaSuccess
  RunReportStatusFailure -> GiteaFailure
  RunReportStatusTimeout -> GiteaError
  RunReportStatusCancelled -> GiteaError

statusPhrase :: RunReportStatus -> Text
statusPhrase = \case
  RunReportStatusInProgress -> "in progress"
  RunReportStatusSuccess -> "succeeded"
  RunReportStatusFailure -> "failed"
  RunReportStatusTimeout -> "timed out"
  RunReportStatusCancelled -> "cancelled"

-- | Absolute link into the garnix UI for this run (Gitea target_url must be
-- absolute, unlike the relative URIs the GitHub reporter uses).
getAbsoluteUrl :: ReportType -> M (Maybe Text)
getAbsoluteUrl buildOrRun = do
  base <- view #baseUrl
  let path = case buildOrRun of
        ReportBuild _name build -> Just $ "/build/" <> build ^. id . to getBuildId . re hashIdText
        ReportRun run -> Just $ "/run/" <> run ^. id . to getRunId . re hashIdText
        MetaCheck -> Nothing
  pure $ (base <>) <$> (relRef =<< path)
  where
    relRef :: Text -> Maybe Text
    relRef p = cs . show <$> (parseRelativeReference (cs p) :: Maybe URI)
