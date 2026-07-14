module Garnix.API.Commits where

import Garnix.API.Runs (RunSummary, toRunSummary)
import Garnix.Access (canCancelBuild, getRepoPublicityForForge, hasAccessTo, hasAccessToRepo)
import Garnix.DB qualified as DB
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import Servant.Auth.Server

data CommitAPI route = CommitAPI
  { _commitAPIgetCommitsForRepo :: route :- "repo" :> Capture "owner" GhRepoOwner :> Capture "repo" GhRepoName :> Get '[JSON] ListCommits,
    _commitAPIgetCommitsForUser :: route :- Get '[JSON] ListCommits,
    _commitAPIgetSingleCommit :: route :- Capture "commit" CommitHash :> Get '[JSON] GetCommit,
    _commitAPIcancelCommit :: route :- Capture "commit" CommitHash :> "cancel" :> Post '[JSON] NoContent
  }
  deriving (Generic)

commitAPI :: AuthResult AuthJwtPayload -> CommitAPI (AsServerT M)
commitAPI (Authenticated ((^. #user) -> user')) =
  CommitAPI
    { _commitAPIgetCommitsForRepo = getCommitsForRepo (Just user'),
      _commitAPIgetCommitsForUser = getCommitsForUser user',
      _commitAPIgetSingleCommit = getSingleCommit (Just user'),
      _commitAPIcancelCommit = cancelCommit user'
    }
commitAPI _ =
  CommitAPI
    { _commitAPIgetCommitsForRepo = getCommitsForRepo Nothing,
      _commitAPIgetCommitsForUser = throw Unauthorized,
      _commitAPIgetSingleCommit = getSingleCommit Nothing,
      _commitAPIcancelCommit = \_ -> throw Unauthorized
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
    _getCommitRuns :: [RunSummary]
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
  pure $ case result of
    CommitEvaluating -> GetCommit summary [] []
    CommitEvaluated _ builds runs ->
      GetCommit
        summary
        (filter (\b -> b ^. packageType /= TypeOverall) builds)
        (map toRunSummary runs)

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
  pure NoContent
