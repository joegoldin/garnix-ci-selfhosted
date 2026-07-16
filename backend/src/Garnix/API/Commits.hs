module Garnix.API.Commits where

import Garnix.API.Runs (RunSummary, toRunSummary)
import Garnix.Access (canCancelBuild, getRepoPublicityForForge, hasAccessTo, hasAccessToRepo)
import Garnix.DB qualified as DB
import Garnix.Monad
import Garnix.Monad.Concurrency (forkM)
import Garnix.Orchestrator qualified as Orchestrator
import Garnix.Prelude
import Garnix.Types
import Servant.Auth.Server

data CommitAPI route = CommitAPI
  { _commitAPIgetCommitsForRepo :: route :- "repo" :> Capture "owner" GhRepoOwner :> Capture "repo" GhRepoName :> Get '[JSON] ListCommits,
    _commitAPIgetCommitsForUser :: route :- Get '[JSON] ListCommits,
    _commitAPIgetSingleCommit :: route :- Capture "commit" CommitHash :> Get '[JSON] GetCommit,
    _commitAPIcancelCommit :: route :- Capture "commit" CommitHash :> "cancel" :> Post '[JSON] NoContent,
    _commitAPIrestartFailed :: route :- Capture "commit" CommitHash :> "restart-failed" :> Post '[JSON] NoContent
  }
  deriving (Generic)

commitAPI :: AuthResult AuthJwtPayload -> CommitAPI (AsServerT M)
commitAPI (Authenticated ((^. #user) -> user')) =
  CommitAPI
    { _commitAPIgetCommitsForRepo = getCommitsForRepo (Just user'),
      _commitAPIgetCommitsForUser = getCommitsForUser user',
      _commitAPIgetSingleCommit = getSingleCommit (Just user'),
      _commitAPIcancelCommit = cancelCommit user',
      _commitAPIrestartFailed = restartFailedCommit user'
    }
commitAPI _ =
  CommitAPI
    { _commitAPIgetCommitsForRepo = getCommitsForRepo Nothing,
      _commitAPIgetCommitsForUser = throw Unauthorized,
      _commitAPIgetSingleCommit = getSingleCommit Nothing,
      _commitAPIcancelCommit = \_ -> throw Unauthorized,
      _commitAPIrestartFailed = \_ -> throw Unauthorized
    }

data ListCommits = ListCommits
  { _listCommitsCommits :: [CommitSummary]
  }
  deriving (Eq, Show, Generic)

instance ToJSON ListCommits where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

data GetCommit = GetCommit
  { _getCommitSummary :: CommitSummary,
    _getCommitBuilds :: [Build],
    _getCommitRuns :: [RunSummary],
    _getCommitRunningBuildIds :: [BuildId]
  }
  deriving (Eq, Show, Generic)

instance ToJSON GetCommit where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

getCommitsForRepo :: (HasCallStack) => Maybe User -> GhRepoOwner -> GhRepoName -> M ListCommits
getCommitsForRepo user repoOwner repoName = do
  -- Forge-aware: publicity comes from GitHub or Gitea (throws NoSuchRepo if the
  -- repo is on neither), then the usual access check (admin/collaborator).
  repoPublicity <- getRepoPublicityForForge repoOwner repoName
  hasAccess <- hasAccessToRepo user repoPublicity repoOwner repoName
  when (not hasAccess) $ throw NoSuchRepo {_owner = repoOwner, _name = repoName}
  ListCommits <$> DB.getCommitsByOwnerAndRepo repoOwner repoName

getCommitsForUser :: User -> M ListCommits
getCommitsForUser user = do
  commits <- DB.getCommitsForReqUser user
  pure $ ListCommits {_listCommitsCommits = commits}

getSingleCommit :: Maybe User -> CommitHash -> M GetCommit
getSingleCommit user' commit = do
  summary <- DB.getCommitSummary commit
  hasAccess <- hasAccessTo user' (summary ^. repoIsPublic) (summary ^. reqUser) (summary ^. repoOwner) (summary ^. repoName)
  when (not hasAccess) $ throw (NoSuchCommit commit)
  result <- DB.getBuildsAndRunsByCommit (summary ^. repoOwner) (summary ^. repoName) commit
  runningIds <- DB.getRunningBuildIdsForCommit (summary ^. repoOwner) (summary ^. repoName) commit
  pure $ case result of
    CommitEvaluating -> GetCommit summary [] [] runningIds
    CommitEvaluated _ builds runs ->
      GetCommit
        -- The summary aggregates the builds table only; fold the runs
        -- (actions, FOD checks, module publish, deployments) into the counts
        -- so an in-flight action shows up in the header and enables
        -- Cancel-all / Restart-failed.
        (addRunCounts runs summary)
        (filter (\b -> b ^. packageType /= TypeOverall) builds)
        (map toRunSummary runs)
        runningIds
  where
    addRunCounts :: [Run] -> CommitSummary -> CommitSummary
    addRunCounts runs summary =
      let count p = fromIntegral $ length $ filter p runs
       in summary
            & succeeded %~ (+ count ((== Just Success) . _runStatus))
            & failed %~ (+ count (\r -> _runStatus r == Just Failure || _runStatus r == Just Timeout))
            & cancelled %~ (+ count ((== Just Cancelled) . _runStatus))
            & running %~ (+ count (\r -> isNothing (_runStatus r) && isJust (_runRunStartedAt r)))
            & pending %~ (+ count (\r -> isNothing (_runStatus r) && isNothing (_runRunStartedAt r)))

-- | Cancel every still-pending build for a commit, including the "overall"
-- eval/starting build the web UI never lists. Lets the user cancel a commit
-- that is still evaluating (before any per-package builds exist).
cancelCommit :: User -> CommitHash -> M NoContent
cancelCommit user commit = do
  summary <- DB.getCommitSummary commit
  hasAccess <-
    canCancelBuild
      (Just user)
      (summary ^. repoIsPublic)
      (summary ^. reqUser)
      (summary ^. repoOwner)
      (summary ^. repoName)
  when (not hasAccess) $ throw (NoSuchCommit commit)
  builds <- DB.getBuildsByCommit (summary ^. repoOwner) (summary ^. repoName) commit
  buildEnd <- liftIO getCurrentTime
  forM_ builds $ \b ->
    when (isNothing (b ^. status))
      $ DB.reportBuildResultDB (b & status ?~ Cancelled & endTime ?~ buildEnd)
  -- Also cancel in-flight runs (actions etc.); the action executor polls its
  -- run row and aborts when it sees Cancelled.
  runs <- DB.getRuns (summary ^. repoOwner) (summary ^. repoName) commit
  forM_ runs $ \r ->
    when (isNothing (_runStatus r))
      $ DB.setRunStatus (_runId r) (Just Cancelled)
  pure NoContent

-- | Restart every failed (failed/timed-out) build of a commit. Package builds
-- are restarted individually; if the failure is the eval/overall build itself
-- (so there are no package builds to restart), the whole commit is re-run.
-- Gated like cancellation: requester, collaborator, or admin.
restartFailedCommit :: User -> CommitHash -> M NoContent
restartFailedCommit user commit = do
  summary <- DB.getCommitSummary commit
  hasAccess <-
    canCancelBuild
      (Just user)
      (summary ^. repoIsPublic)
      (summary ^. reqUser)
      (summary ^. repoOwner)
      (summary ^. repoName)
  when (not hasAccess) $ throw (NoSuchCommit commit)
  builds <- DB.getBuildsByCommit (summary ^. repoOwner) (summary ^. repoName) commit
  runs <- DB.getRuns (summary ^. repoOwner) (summary ^. repoName) commit
  let isFailed b = b ^. status == Just Failure || b ^. status == Just Timeout
      failedPackageBuilds = filter (\b -> isFailed b && b ^. packageType /= TypeOverall) builds
      failedOverall = filter (\b -> isFailed b && b ^. packageType == TypeOverall) builds
      failedRuns = filter (\r -> _runStatus r == Just Failure || _runStatus r == Just Timeout) runs
      restarter = user ^. githubLogin
  if not (null failedRuns)
    -- A failed run (action/deploy/FOD/module publish) can only be re-executed
    -- by re-running the whole commit: runs are driven by the full pipeline,
    -- not by a per-package build.
    then case builds of
      anyBuild : _ -> forkM $ Orchestrator.restartCommit restarter anyBuild
      [] -> pure ()
    else case (failedPackageBuilds, failedOverall) of
      ([], overallBuild : _) -> forkM $ Orchestrator.restartCommit restarter overallBuild
      _ -> forM_ failedPackageBuilds $ \b -> forkM $ Orchestrator.restartBuild restarter b
  pure NoContent
