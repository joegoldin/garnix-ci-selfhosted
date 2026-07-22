module Garnix.API.Runs where

import Garnix.API.Builds.Types
import Garnix.Access (Access (..), getRunWithAccess)
import Garnix.BuildLogs qualified as BuildLogs
import Garnix.DB qualified as DB
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import Garnix.UserLogs (getRunLogLines)
import Servant.API (Put)
import Servant.Auth.Server (AuthResult (..))

data RunAPI route = RunAPI
  { _runAPIGetRun :: route :- Capture "runId" RunId :> Get '[JSON] RunSummary,
    _runAPIUpdateRun :: route :- Capture "runId" RunId :> ReqBody '[JSON] BuildUpdate :> Put '[JSON] (),
    _runAPIGetLogs :: route :- Capture "runId" RunId :> "logs" :> QueryParam "after" UTCTime :> Get '[JSON] BuildLogs
  }
  deriving stock (Generic)

runAPI :: AuthResult AuthJwtPayload -> RunAPI (AsServerT M)
runAPI (Authenticated ((^. #user) -> user)) =
  RunAPI
    { _runAPIGetRun = getRun (Just user),
      _runAPIUpdateRun = updateRun (Just user),
      _runAPIGetLogs = getRunLogs (Just user)
    }
runAPI _ =
  RunAPI
    { _runAPIGetRun = getRun Nothing,
      _runAPIUpdateRun = updateRun Nothing,
      _runAPIGetLogs = getRunLogs Nothing
    }

getRun :: Maybe User -> RunId -> M RunSummary
getRun mUser runId = do
  run <- getRunWithAccess Read mUser runId
  waitingOn <- if isJust (run ^. status) then pure [] else getRunWaitNodes run
  pure $ (toRunSummary run) {_runSummaryWaitingOn = waitingOn}

getRunWaitNodes :: Run -> M [WaitNode]
getRunWaitNodes run = do
  tracker <- view #buildWaitTracker
  builds <- DB.getBuildsByCommit (run ^. repoUser) (run ^. repoName) (run ^. gitCommit)
  forM (filter (isNothing . (^. status)) builds) $ \build -> do
    runStartedAt <- DB.getBuildRunStartedAt (build ^. id)
    children <- BuildLogs.buildWaitNodes tracker build runStartedAt
    let buildId = getHashId . getBuildId $ build ^. id
    pure
      WaitNode
        { _waitNodeId = "build:" <> buildId,
          _waitNodeKind = "build",
          _waitNodeLabel = review asPackageType (build ^. packageType) <> " " <> getPackageName (build ^. package),
          _waitNodeDetail = Just $ if isJust runStartedAt then "Running" else "Pending",
          _waitNodeHref = Just $ "/build/" <> buildId,
          _waitNodeStartedAt = runStartedAt <|> Just (build ^. startTime),
          _waitNodeLastActivityAt = runStartedAt,
          _waitNodeChildren = children
        }

-- | Mirrors 'Garnix.API.Builds.updateBuild': the only supported update is
-- cancellation. Setting the run row to Cancelled is enough — the action
-- executor polls its row and aborts (see 'abortOnRunCancellation'); runs
-- without an abort poller (FOD checks) just finish in the background, and
-- 'DB.setRunStatus' refuses to overwrite the final status.
updateRun :: Maybe User -> RunId -> BuildUpdate -> M ()
updateRun mUser runId runUpdate =
  case runUpdate ^. status of
    Just Cancelled -> do
      run <- getRunWithAccess Cancel mUser runId
      if isJust (run ^. status)
        then throw (RunAlreadyStopped runId)
        else DB.setRunStatus runId (Just Cancelled)
    Just _ -> throw (InvalidBuildUpdate runUpdate)
    Nothing -> pure ()

getRunLogs :: Maybe User -> RunId -> Maybe UTCTime -> M BuildLogs
getRunLogs mUser runId mAfter = do
  run <- getRunWithAccess Read mUser runId
  let maxResults = 4096
  logs <- getRunLogLines run maxResults mAfter
  let finished = isJust (run ^. status) && length logs < maxResults
  pure $ BuildLogs finished maxResults logs

data RunSummary = RunSummary
  { _runSummaryId :: Text,
    _runSummaryName :: Text,
    _runSummaryRepoUser :: GhRepoOwner,
    _runSummaryRepoName :: GhRepoName,
    _runSummaryGitCommit :: CommitHash,
    _runSummaryBranch :: Maybe Branch,
    _runSummaryStatus :: Maybe Status,
    _runSummaryStartTime :: UTCTime,
    _runSummaryEndTime :: Maybe UTCTime,
    _runSummaryRunStartedAt :: Maybe UTCTime,
    _runSummaryWaitingOn :: [WaitNode]
  }
  deriving (Eq, Show, Generic)

toRunSummary :: Run -> RunSummary
toRunSummary run@(Run {_runId, _runName, _runStatus, _runStartTime, _runEndTime}) =
  RunSummary
    { _runSummaryId = getRunId _runId ^. re hashIdText,
      _runSummaryName = _runName,
      _runSummaryRepoUser = run ^. repoUser,
      _runSummaryRepoName = run ^. repoName,
      _runSummaryGitCommit = run ^. gitCommit,
      _runSummaryBranch = run ^. branch,
      _runSummaryStatus = _runStatus,
      _runSummaryStartTime = _runStartTime,
      _runSummaryEndTime = _runEndTime,
      _runSummaryRunStartedAt = run ^. runStartedAt,
      _runSummaryWaitingOn = []
    }

instance ToJSON RunSummary where
  toEncoding = ourToEncoding
  toJSON = ourToJSON
