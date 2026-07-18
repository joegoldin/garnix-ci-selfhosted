module Garnix.Hosting.Helpers
  ( getRunningAndRecentServersForOwners,
    RunningServer (..),
  )
where

import Data.Aeson qualified as Aeson
import Data.Maybe (mapMaybe)
import Database.PostgreSQL.Typed (pgSQL)
import Garnix.DB qualified as DB
import Garnix.Hosting.ServerPool.Types ()
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types

data ServerStatus
  = Online
  | Failed
  | Booting
  | Ended
  deriving stock (Eq, Show, Generic)

instance ToJSON ServerStatus where
  toJSON = ourToJSON

data RunningServer = RunningServer
  { _runningServerId :: ServerId,
    _runningServerType :: DeploymentType,
    _runningServerStatus :: ServerStatus,
    _runningServerRepoOwner :: GhRepoOwner,
    _runningServerRepoName :: GhRepoName,
    _runningServerPackageName :: PackageName,
    _runningServerCreatedAt :: Maybe UTCTime,
    _runningServerConfigurationBuildId :: BuildId,
    _runningServerCommit :: CommitHash,
    _runningServerIpv4 :: Maybe Text,
    _runningServerDeployLogs :: Text,
    -- | Public URL the deployed server is reachable at once Online
    -- (<pkg>.<branch|pull-N>.<repo>.<owner>.<hostingDomain>).
    _runningServerUrl :: Text,
    -- | Raw servers.exposed blob ({ssh_port, tcp, http}) when the server has
    -- exposed SSH/ports; the frontend builds ssh commands + port links from it.
    _runningServerExposed :: Maybe Aeson.Value,
    -- | The latest resource sample pushed by this server's guest reporter
    -- (CPU %, memory used/total). 'Nothing' until the guest reports; the
    -- Servers-page row renders it compactly and the Monitor page draws history.
    _runningServerStats :: Maybe ServerStatsSample,
    -- | Declared extra hostnames (servers.domains) this server answers on; the
    -- Servers-page (i) menu renders the DNS records to set for each.
    _runningServerDomains :: [Text]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON RunningServer where
  toJSON = ourToJSON

getRunningAndRecentServersForOwners :: [GhRepoOwner] -> M [RunningServer]
getRunningAndRecentServersForOwners owners = do
  domain <- view #hostingDomain
  exposures <- DB.getServerExposures
  stats <- DB.getLatestServerStats
  domainsAssoc <- DB.getServerDomains
  let mkUrl typ repoName repoUser packageName =
        "https://"
          <> getPackageName packageName
          <> "."
          <> fromDeploymentType getBranch (("pull-" <>) . show . getGhPullRequestId) typ
          <> "."
          <> getGhRepoName repoName
          <> "."
          <> getGhLogin (getGhRepoOwner repoUser)
          <> "."
          <> domain
  mapMaybe
    ( \(id, pr, branch, readyAt, endedAt, repoUser, repoName, packageName, createdAt, buildId, commit, ipv4, logs) -> do
        typ <- serverDeploymentType pr branch
        status <- serverStatus readyAt endedAt
        pure $ RunningServer id typ status repoUser repoName packageName createdAt buildId commit ipv4 logs (mkUrl typ repoName repoUser packageName) (lookup id exposures) (lookup id stats) (fromMaybe [] (lookup id domainsAssoc))
    )
    <$> DB.pgQuery
      [pgSQL|
        SELECT
          servers.id,
          servers.pull_request,
          builds.branch,
          servers.ready_at,
          servers.ended_at,
          builds.repo_user,
          builds.repo_name,
          builds.package,
          servers.created_at,
          servers.configuration_build_id,
          builds.git_commit,
          servers.ipv4,
          servers.deploy_logs
        FROM servers
        INNER JOIN builds
        ON servers.configuration_build_id = builds.id
        WHERE builds.repo_user = ANY(${owners})
        AND (servers.ended_at IS NULL OR servers.ended_at > now() - interval '24' hour)
        ORDER BY servers.created_at DESC
      |]
  where
    serverDeploymentType :: Maybe GhPullRequestId -> Maybe Branch -> Maybe DeploymentType
    serverDeploymentType pr branch = case (pr, branch) of
      (Just prId, _) -> Just $ GhPrDeployment prId
      (Nothing, Just branch) -> Just $ BranchDeployment branch
      (Nothing, Nothing) -> Nothing
    serverStatus :: Maybe UTCTime -> Maybe UTCTime -> Maybe ServerStatus
    serverStatus readyAt endedAt = case (readyAt, endedAt) of
      (Nothing, Nothing) -> Just Booting
      (Just _, Nothing) -> Just Online
      (Just _, Just _) -> Just Ended
      (Nothing, Just _) -> Nothing
