module Garnix.Hosting.Deploy
  ( rolloutNewServerVersion,
    startServer,
    stopUnusedServers,
    stopServer,
    redeployServer,
    checkDeployPlan,
  )
where

import Control.Concurrent.Async.Lifted qualified as Async
import Control.Lens (traversed)
import Cradle
import Data.Aeson qualified as Aeson
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Garnix.API.Keys (getRepoKeys)
import Garnix.BuildLogs.Types (mkLogLine)
import Garnix.DB qualified as DB
import Garnix.LocalProvisioner (exposeServer)
import Garnix.Duration
import Garnix.Hosting.ServerPool qualified as ServerPool
import Garnix.Hosting.ServerPool.Types
import Garnix.Monad
import Garnix.Monad.Polling (PollingConfig (PollingConfig), withPolling)
import Garnix.Monad.SubProcess (runSubProcess)
import Garnix.Nix.StorePath (withStorePath)
import Garnix.Nix.Types
import Garnix.Prelude
import Garnix.Reporters.Utils (withRunReporter)
import Garnix.Request
import Garnix.Types
import Garnix.YamlConfig
import Network.Wreq qualified as Wreq
import System.Process qualified as Proc

-- | Deploys new server versions, deletes old ones.
rolloutNewServerVersion ::
  Reporter ->
  CommitInfo ->
  DeploymentType ->
  M [ServerInfo]
rolloutNewServerVersion reporter commitInfo deploymentType =
  withTextSpan ("deployment_type", fromDeploymentType (const "branch") (const "pr") deploymentType)
    $ (<?> "Rolling out new servers")
    $ do
      plan <- getDeployPlan reporter commitInfo deploymentType
      executeDeployPlan reporter commitInfo plan deploymentType

stopUnusedServers :: M ()
stopUnusedServers = do
  domain <- view #hostingDomain
  (PrHostList runningServers) <- DB.getShutdownCandidates
  heartbeat <- DB.getRecentHeartbeats
  let toSpinDown = filter (haveNotSentHeartbeat domain heartbeat) runningServers
  traverse_ (\s -> stopServer (s ^. serverId) (s ^. provisionerId)) toSpinDown
  where
    haveNotSentHeartbeat :: Text -> [Text] -> Host -> Bool
    haveNotSentHeartbeat domain heartbeats host =
      let hostName = hostToDomainName host <> "." <> domain
       in hostName `notElem` heartbeats

getDeployPlan ::
  Reporter ->
  CommitInfo ->
  DeploymentType ->
  M DeployPlan
getDeployPlan reporter commitInfo deploymentType = do
  withErrorReporter reporter commitInfo $ do
    cfg <- getConfig
    let wantedPackagesMapping :: Map PackageName (ServerTier, Bool, ServerSection) = Map.fromList $ case deploymentType of
          BranchDeployment thisBranch -> flip mapMaybe (cfg ^. serverSection)
            $ \s -> case s ^. deploySection of
              OnBranch branch serverTier isPrimary | branch == thisBranch -> Just (s ^. configuration, (serverTier, isPrimary, s))
              _ -> Nothing
          GhPrDeployment _prId ->
            (cfg ^. serverSection)
              & filter (\s -> s ^. deploySection == OnPullRequest)
              & map (\s -> (s ^. configuration, (def, False, s)))
    let wantedPackages = Map.keys wantedPackagesMapping
    existing <- DB.getRunningServersOf (commitInfo ^. repoInfo) deploymentType
    wantedBuilds <- withPolling (PollingConfig (fromSeconds @Int 2) (fromHours @Int 2)) $ do
      builds <- DB.getLatestBuildsMatching (commitInfo ^. repoInfo) (commitInfo ^. commit)
      let overallPackageFinished = case find (\build -> build ^. packageType == TypeOverall) builds of
            Nothing -> False
            Just b -> isJust (b ^. status)
          wantedAndStarted =
            filter
              ( \build ->
                  build
                    ^. package
                    `elem` wantedPackages
                    && build
                    ^. packageType
                    == TypeNixosConfiguration
              )
              builds
          wantedAndFinished = filter (\build -> isJust (build ^. status)) wantedAndStarted
          wantedAndNotStarted = filter (`notElem` wantedAndStarted ^.. each . package) wantedPackages
          uploadedAllBuilds = all (\b -> b ^. uploadedToCache == Just True) wantedAndFinished
      when (overallPackageFinished && not (null wantedAndNotStarted)) $ do
        throw $ DeploymentWantsNixosConfigurationsThatDontExist wantedAndNotStarted
      pure
        $ if sort wantedPackages == sort (wantedAndFinished ^.. each . package) && uploadedAllBuilds
          then Just wantedAndFinished
          else Nothing

    let toRedeploy =
          [ (server, build)
            | server <- existing,
              build <- wantedBuilds,
              server ^. buildPersistenceName == build ^. persistenceName,
              isJust (build ^. persistenceName)
          ]
        toSpinDown = filter (`notElem` (fst <$> toRedeploy)) existing
    toSpinUp <-
      wantedBuilds
        & filter (`notElem` (snd <$> toRedeploy))
        & mapM
          ( \build -> case Map.lookup (build ^. package) wantedPackagesMapping of
              Just (serverTier, domainIsPrimary, section) -> do
                useDefaultAuthentik <- case _serverSectionAuthentikSection section of
                  Nothing -> pure False
                  Just "default" -> pure True
                  Just other -> throw $ OtherError $ "Unsupported servers[].authentik value " <> show other <> "; only \"default\" is supported"
                -- Split garnix.yaml servers[].ports into http (Traefik subdomains)
                -- and tcp (raw host-port DNAT); ssh keys/expose come straight
                -- off the section.
                let httpPorts = [(_serverPortName p, _serverPortPort p) | p <- _serverSectionPorts section, _serverPortType p == HttpPort]
                    tcpPorts = [(_serverPortName p, _serverPortPort p) | p <- _serverSectionPorts section, _serverPortType p == TcpPort]
                pure
                  $ ServerToSpinUp
                    { serverTier,
                      build,
                      domainIsPrimary,
                      useDefaultAuthentik,
                      sshKeys = _serverSectionSshKeys section,
                      sshExpose = _serverSectionSshExpose section,
                      httpPorts,
                      tcpPorts
                    }
              Nothing -> throw $ OtherError "impossible: wantedPackagesMap should contain all deployable packages"
          )
    let plan = DeployPlan toSpinDown toSpinUp toRedeploy
    unless (null toSpinUp) $ do
      checkDeployPlan (commitInfo ^. repoInfo) deploymentType plan
    pure plan

-- | Will catch all exceptions, create a new reporter to report the error to the user and rethrow.
withErrorReporter :: Reporter -> CommitInfo -> M a -> M a
withErrorReporter reporter commitInfo action = do
  checkResult <- try action
  case checkResult of
    Left error -> do
      run <- DB.newRun "deployment plan" commitInfo
      runReporter <- createNewRun reporter (ReportRun run)
      reportLogs runReporter (mkLogLine $ userMessage $ toErrorDetails error)
      reportComplete runReporter RunReportStatusFailure
      rethrow error
    Right a -> pure a

checkDeployPlan ::
  RepoInfo ->
  DeploymentType ->
  DeployPlan ->
  M ()
checkDeployPlan repoInfo deploymentType plan = do
  -- No billing/entitlement limits in this fork: only structural checks remain.
  checkSubdomainValidity repoInfo deploymentType $ fmap (^. #build) $ plan ^. #toSpinUp
  checkAllBuildsSucceeded plan

checkSubdomainValidity ::
  RepoInfo ->
  DeploymentType ->
  [Build] ->
  M ()
checkSubdomainValidity
  (RepoInfo _ _ _ (GhRepoOwner (GhLogin repoOwner')) (GhRepoName repoName'))
  deploymentType
  wantedServers = do
    unless (isValidSubdomainString repoOwner')
      $ throw
      $ NameIsNotValidSubdomain RepoOwnerSubdomain repoOwner'
    unless (isValidSubdomainString repoName')
      $ throw
      $ NameIsNotValidSubdomain RepoNameSubdomain repoName'
    case deploymentType of
      BranchDeployment (Branch branch') -> do
        unless (isValidSubdomainString branch')
          $ throw
          $ NameIsNotValidSubdomain BranchSubdomain branch'
      GhPrDeployment _ -> pure ()
    forM_ wantedServers $ \build -> do
      let packageName = getPackageName $ build ^. package
      unless (isValidSubdomainString packageName)
        $ throw
        $ NameIsNotValidSubdomain PackageNameSubdomain packageName
      let persistence = build ^. persistenceName
      forM_ persistence $ \persistenceName -> do
        unless (isValidSubdomainString persistenceName)
          $ throw
          $ NameIsNotValidSubdomain PersistenceNameSubdomain persistenceName

checkAllBuildsSucceeded :: DeployPlan -> M ()
checkAllBuildsSucceeded plan = do
  forM_ (plan ^.. #toSpinUp . each . #build) $ \build -> do
    let packageName = getPackageName $ build ^. package
    case build ^. status of
      Just Success -> pure ()
      Just Failure -> throw $ OtherError $ packageName <> " failed"
      Just Timeout -> throw $ OtherError $ packageName <> " timed out"
      Just Cancelled -> throw $ OtherError $ packageName <> " cancelled"
      -- this should be unreachable since checkAllBuildsSucceeded is only called after waiting for all builds to finish
      Nothing -> throw $ OtherError $ packageName <> " has no status"

executeDeployPlan ::
  Reporter ->
  CommitInfo ->
  DeployPlan ->
  DeploymentType ->
  M [ServerInfo]
executeDeployPlan = curry4
  $ mockable #executeDeployPlanMock
  $ \(reporter, commitInfo, DeployPlan currentServers wantedServers redeployServers, deploymentType) -> do
    serverInfos <- Async.mapConcurrently (startServer reporter commitInfo deploymentType) wantedServers
    redeployedServers <- Async.mapConcurrently (uncurry (redeployServer reporter commitInfo deploymentType)) redeployServers
    deployedServerInfos <- toggleServerFlags serverInfos currentServers <?> "Toggling servers ready flags."
    Async.mapConcurrently_ (\s -> stopServer (s ^. id) (s ^. provisionedServerId)) currentServers
    return (deployedServerInfos <> redeployedServers)

stopServer :: ServerId -> ProvisionedServerId -> M ()
stopServer serverId provisionerId = do
  deleteServer provisionerId
  DB.deleteServerDB serverId

startServer ::
  Reporter ->
  CommitInfo ->
  DeploymentType ->
  ServerToSpinUp ->
  M ServerInfo
startServer = curry4
  $ mockable #startServerMock
  $ \(reporter, commitInfo, deploymentType, serverToSpinUp) -> do
    run <- DB.newRun ("deployment " <> getPackageName (serverToSpinUp ^. #build . package)) commitInfo
    withRunReporter reporter (ReportRun run) $ \runReporter -> do
      domain <- view #hostingDomain
      let publicHost =
            getPackageName (serverToSpinUp ^. #build . package)
              <> "."
              <> fromDeploymentType getBranch (("pull-" <>) . show . getGhPullRequestId) deploymentType
              <> "."
              <> getGhRepoName (commitInfo ^. repoInfo . ghRepoName)
              <> "."
              <> getGhLogin (getGhRepoOwner (commitInfo ^. repoInfo . ghRepoOwner))
              <> "."
              <> domain
      serverInfo <- ServerPool.createServer (commitInfo ^. repoInfo) deploymentType serverToSpinUp
      when (serverToSpinUp ^. #useDefaultAuthentik)
        $ copyDefaultAuthentikEnv serverInfo publicHost
        <?> "Copying default Authentik credentials"
      -- Authorize SSH for the garnix user when the user opted in (sshExpose or
      -- explicit sshKeys); this also grants the deployer's own GitHub keys.
      when (serverToSpinUp ^. #sshExpose || not (null (serverToSpinUp ^. #sshKeys)))
        $ copyAuthorizedKeys serverInfo (commitInfo ^. reqUser) (serverToSpinUp ^. #sshKeys)
        <?> "Authorizing SSH keys"
      -- Public port exposure (DNAT) only makes sense with the local
      -- provisioner; persist whatever it (plus the http routers) exposes, but
      -- only when the server actually declares ssh/ports.
      let wantsExposure =
            serverToSpinUp ^. #sshExpose
              || not (null (serverToSpinUp ^. #httpPorts))
              || not (null (serverToSpinUp ^. #tcpPorts))
      when wantsExposure $ do
        exposeResult <- exposeServerPorts serverInfo serverToSpinUp
        DB.setServerExposed (serverInfo ^. id) (exposedBlob serverToSpinUp exposeResult)
      (serverInfo, stderr) <-
        setupServer (commitInfo ^. repoInfo) (serverToSpinUp ^. #build) serverInfo `whenError` \error -> do
          let logs = showPretty (err error)
          DB.appendToServerDeployLog (serverInfo ^. id) logs
      let logs =
            T.unlines
              [ "Server has been successfully deployed to: https://"
                  <> publicHost,
                "ipv4: " <> serverInfo ^. ipv4Addr,
                "ipv6: " <> serverInfo ^. ipv6Addr,
                "",
                "logs:"
                  <> stderr
              ]
      DB.appendToServerDeployLog (serverInfo ^. id) logs
      reportLogs runReporter (mkLogLine logs)
      reportComplete runReporter RunReportStatusSuccess
      pure serverInfo

redeployServer :: Reporter -> CommitInfo -> DeploymentType -> ServerInfo -> Build -> M ServerInfo
redeployServer reporter commitInfo deploymentType serverInfo build = do
  withStorePath build "out" $ \case
    Nothing -> throw $ OtherError "Store path is missing"
    Just storePath -> do
      run <- DB.newRun ("redeployment " <> getPackageName (build ^. package)) commitInfo
      withRunReporter reporter (ReportRun run) $ \runReporter -> do
        copyClosure (SshUser "garnix") serverInfo storePath <?> "Copying closure for redeployment"
        deploymentLogs <- switchToConfiguration (SshUser "garnix") serverInfo storePath <?> "Switching to redeployment configuration"
        now <- liftIO getCurrentTime
        let serverInfo' =
              serverInfo
                & configurationBuildId
                .~ build
                ^. id
                & readyAt
                ?~ now
        DB.updateServerPostDeploy serverInfo' <?> "Updating DB about the redeployed server"
        domain <- view #hostingDomain
        let logs =
              T.unlines
                [ "Server has been successfully redeployed to: https://"
                    <> getPackageName (build ^. package)
                    <> "."
                    <> fromDeploymentType getBranch (("pull-" <>) . show . getGhPullRequestId) deploymentType
                    <> "."
                    <> getGhRepoName (commitInfo ^. repoInfo . ghRepoName)
                    <> "."
                    <> getGhLogin (getGhRepoOwner (commitInfo ^. repoInfo . ghRepoOwner))
                    <> "."
                    <> domain,
                  "ipv4: " <> serverInfo ^. ipv4Addr,
                  "ipv6: " <> serverInfo ^. ipv6Addr,
                  "",
                  "logs:"
                    <> deploymentLogs
                ]
        reportLogs runReporter (mkLogLine logs)
        reportComplete runReporter RunReportStatusSuccess
        pure serverInfo'

-- | Toggles the wanted servers to be ready and the current servers to end.
toggleServerFlags :: [ServerInfo] -> [ServerInfo] -> M [ServerInfo]
toggleServerFlags wanted current = do
  currentTime <- liftIO getCurrentTime
  let wanted' = wanted & traversed . readyAt ?~ currentTime
      current' = current & traversed . endedAt ?~ currentTime
  DB.pgTransaction $ traverse_ DB.updateServerPostDeploy (wanted' <> current')
  pure wanted'

-- | Provisions a *new* server, and deploys the given NixOS configuration there.
--
-- Does *not* delete the old server.
setupServer ::
  RepoInfo ->
  Build ->
  ServerInfo ->
  M (ServerInfo, Text)
setupServer = curry3
  $ mockable #setupServerMock
  $ \(repoInfo, build, serverInfo) -> do
    withStorePath build "out" $ \case
      Nothing -> throw $ OtherError "Store path is missing"
      Just storePath -> do
        copyKeys repoInfo serverInfo
        copyClosure (SshUser "root") serverInfo storePath <?> "Copying closure"
        stderr <- switchToConfiguration (SshUser "root") serverInfo storePath <?> "Switching to configuration"
        return (serverInfo, stderr)

newtype SshUser = SshUser Text

copyClosure :: SshUser -> ServerInfo -> StorePath -> M ()
copyClosure (SshUser user) server storePath = do
  (ip, sshArgs) <- ServerPool.sshArgsFor server
  retryingFor (fromMinutes @Int 1) $ do
    runSubProcess
      $ cmd "nix-copy-closure"
      & addArgs ["--to", user <> "@" <> ip, cs storePath]
      & modifyEnvVar "NIX_SSHOPTS" (const $ Just $ cs $ T.intercalate " " sshArgs)

copyKeys :: RepoInfo -> ServerInfo -> M ()
copyKeys repoInfo server = do
  (ip, sshArgs) <- ServerPool.sshArgsFor server
  let keyLocation = "/var/garnix/keys/repo-key"
  let doRemotely cmd =
        runSubProcess
          $ Cradle.cmd "ssh"
          & addArgs (sshArgs <> ["root@" <> cs ip, cmd])
  doRemotely $ "mkdir -p " <> cs (takeDirectory keyLocation)
  (_, privKey) <-
    getRepoKeys (repoInfo ^. ghRepoOwner) (repoInfo ^. ghRepoName)
      <?> "Get private keys"
  repoSecretsKey <- view #repoSecretsEncryptionKeyPath
  exportResult <-
    liftIO
      ( exportKeys
          ExportKeysOpts
            { privateKey = privKey,
              ipAddr = ip,
              targetPath = keyLocation,
              sshArgs
            }
          repoSecretsKey
      )
      <?> "Export private keys to server"
  whenIs _Left exportResult $ throw . ProvisioningError
  doRemotely $ "chmod 400 " <> cs keyLocation

-- | Drop garnix's own OIDC client credentials onto a guest that opted in via
-- garnix.yaml (servers[].authentik = "default"). Written as oauth2-proxy env
-- vars to /var/garnix/keys/default-authentik.env (root-only), consumed by the
-- garnix-authentik guest module's mode = "default". Delivered over ssh stdin
-- so the secret never lands in process args or the store.
copyDefaultAuthentikEnv :: ServerInfo -> Text -> M ()
copyDefaultAuthentikEnv server publicHost = do
  cfg <-
    view #defaultAuthentik >>= \case
      Just cfg -> pure cfg
      Nothing ->
        throw
          $ OtherError
            "servers[].authentik = \"default\" requires the backend to be configured with garnix's own OIDC client (GARNIX_DEFAULT_AUTHENTIK_ISSUER / GARNIX_DEFAULT_AUTHENTIK_CLIENT_ID / GARNIX_DEFAULT_AUTHENTIK_CLIENT_SECRET_FILE; services.garnixServer.defaultAuthentik)"
  secret <- T.strip <$> liftIO (TIO.readFile (_defaultAuthentikClientSecretFile cfg))
  (ip, sshArgs) <- ServerPool.sshArgsFor server
  let envLocation = "/var/garnix/keys/default-authentik.env" :: Text
      contents =
        T.unlines
          [ "OAUTH2_PROXY_OIDC_ISSUER_URL=" <> _defaultAuthentikIssuerUrl cfg,
            "OAUTH2_PROXY_CLIENT_ID=" <> _defaultAuthentikClientId cfg,
            "OAUTH2_PROXY_CLIENT_SECRET=" <> secret,
            "OAUTH2_PROXY_REDIRECT_URL=https://" <> publicHost <> "/oauth2/callback",
            "OAUTH2_PROXY_WHITELIST_DOMAINS=" <> publicHost,
            "GARNIX_PUBLIC_URL=https://" <> publicHost
          ]
  (exitCode, _, _) <-
    liftIO
      $ Proc.readProcessWithExitCode
        "ssh"
        ((cs <$> sshArgs) <> ["root@" <> cs ip, "umask 077 && mkdir -p /var/garnix/keys && cat > " <> cs envLocation <> " && chmod 400 " <> cs envLocation])
        (cs contents)
  case exitCode of
    ExitSuccess -> pure ()
    ExitFailure _ -> throw $ OtherError "Exporting default Authentik credentials to the server failed"

-- | Authorize the deployer's GitHub keys (best-effort) plus any garnix.yaml
-- sshKeys for the guest's `garnix` user, by dropping an authorized_keys file
-- the guest profile reads via authorizedKeys.keyFiles. No-op with no keys.
copyAuthorizedKeys :: ServerInfo -> GhLogin -> [Text] -> M ()
copyAuthorizedKeys server deployer extraKeys = do
  githubKeys <- fetchGithubKeys deployer
  let keys = filter (not . T.null . T.strip) (githubKeys <> extraKeys)
  unless (null keys) $ do
    (ip, sshArgs) <- ServerPool.sshArgsFor server
    let keyFile = "/var/garnix/keys/authorized_keys" :: Text
    (exitCode, _, _) <-
      liftIO
        $ Proc.readProcessWithExitCode
          "ssh"
          ((cs <$> sshArgs) <> ["root@" <> cs ip, "mkdir -p /var/garnix/keys && cat > " <> cs keyFile <> " && chmod 444 " <> cs keyFile])
          (cs (T.unlines keys))
    case exitCode of
      ExitSuccess -> pure ()
      ExitFailure _ -> throw $ OtherError "Writing authorized_keys to the server failed"

-- | The deployer's public SSH keys, via GitHub's @<login>.keys@ endpoint.
-- Best-effort: any failure (network, non-GitHub forge, 404) yields no keys.
fetchGithubKeys :: GhLogin -> M [Text]
fetchGithubKeys login =
  ( do
      resp <-
        withWreqOptions $ \opts ->
          Wreq.getWith opts (cs ("https://github.com/" <> getGhLogin login <> ".keys"))
      pure $ filter (not . T.null . T.strip) $ T.lines $ cs (resp ^. Wreq.responseBody)
  )
    `catchAny` const (pure [])

-- | Ask the local provisioner to expose SSH/tcp ports via host-port DNAT, when
-- the provisioner socket is configured and something was requested. Returns
-- Nothing on the Hetzner path or when nothing needs exposing.
exposeServerPorts :: ServerInfo -> ServerToSpinUp -> M (Maybe ExposeResult)
exposeServerPorts server serverToSpinUp = do
  socket <- view #provisionerSocket
  let sshExpose' = serverToSpinUp ^. #sshExpose
      tcpGuestPorts = snd <$> serverToSpinUp ^. #tcpPorts
  case socket of
    Just sock
      | sshExpose' || not (null tcpGuestPorts) ->
          Just <$> exposeServer sock (_serverInfoProvisionedServerId server) sshExpose' tcpGuestPorts
    _ -> pure Nothing

-- | The per-server exposure blob stored in servers.exposed:
-- @{"ssh_port": Int|null, "tcp": [{name,guest,host}], "http": [{name,port}]}@.
exposedBlob :: ServerToSpinUp -> Maybe ExposeResult -> Aeson.Value
exposedBlob serverToSpinUp exposeResult =
  Aeson.object
    [ "ssh_port" Aeson..= (exposeResult >>= _exposeResultSshPort),
      "tcp" Aeson..= tcpEntries,
      "http" Aeson..= httpEntries
    ]
  where
    hostForGuest = maybe [] _exposeResultTcpPorts exposeResult
    tcpEntries =
      [ Aeson.object ["name" Aeson..= name, "guest" Aeson..= guest, "host" Aeson..= host]
      | (name, guest) <- serverToSpinUp ^. #tcpPorts,
        host <- toList (lookup guest hostForGuest)
      ]
    httpEntries =
      [ Aeson.object ["name" Aeson..= name, "port" Aeson..= port]
      | (name, port) <- serverToSpinUp ^. #httpPorts
      ]

switchToConfiguration :: SshUser -> ServerInfo -> StorePath -> M Text
switchToConfiguration (SshUser user) server storePath = do
  (ip, sshArgs) <- ServerPool.sshArgsFor server
  StderrRaw stderr <-
    withError (errLens %~ toActivationError server)
      $ runSubProcess
      $ cmd "ssh"
      & addArgs
        ( sshArgs
            <> [ user <> "@" <> ip,
                 "sudo",
                 cs $ cs storePath </> "bin/switch-to-configuration",
                 "switch"
               ]
        )
      & silenceStdout
  pure $ cs stderr
  where
    toActivationError serverInfo = \case
      RunProcessError {stdErr} ->
        ActivationError serverInfo stdErr
      error -> error
