module Garnix.Hosting.Deploy
  ( rolloutNewServerVersion,
    startServer,
    cleanupUnreadyServers,
    stopUnusedServers,
    stopServer,
    redeployServer,
    checkDeployPlan,
    statsEnvContents,
    parseLoginUsers,
  )
where

import Control.Concurrent.Async.Lifted qualified as Async
import Control.Lens (traversed)
import Cradle
import Data.Aeson qualified as Aeson
import Data.Containers.ListUtils (nubOrd)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Garnix.API.Keys (getRepoKeys)
import Garnix.BuildLogs.Types (mkLogLine)
import Garnix.DB qualified as DB
import Garnix.Duration
import Garnix.Entitlements (getConfiguredEvalTimeout)
import Garnix.FlakeInputAuthorization (isExternalForkPr)
import Garnix.Hosting.Domains qualified as Domains
import Garnix.Hosting.LogStream qualified as ServerLogStream
import Garnix.Hosting.ServerPool qualified as ServerPool
import Garnix.Hosting.ServerPool.Types
import Garnix.LocalProvisioner (exposeServer)
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
      servers <- executeDeployPlan reporter commitInfo plan deploymentType
      -- Consume any single-deployment target now the rollout succeeded, so it
      -- can't leak into a later full rebuild of the same commit (the PR redeploy
      -- path reuses the real commit SHA). A no-op when none was set.
      DB.setManualDeployTarget
        (commitInfo ^. repoInfo . ghRepoOwner)
        (commitInfo ^. repoInfo . ghRepoName)
        (commitInfo ^. commit)
        Nothing
      pure servers

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
    evalTimeout <-
      getConfiguredEvalTimeout
        (commitInfo ^. repoInfo . ghRepoOwner)
        (commitInfo ^. repoInfo . ghRepoName)
    cfg <- getConfig evalTimeout
    let fullWantedPackagesMapping :: Map PackageName (ServerTier, Bool, ServerSection) = Map.fromList $ case deploymentType of
          BranchDeployment thisBranch -> flip mapMaybe (cfg ^. serverSection)
            $ \s -> case s ^. deploySection of
              OnBranch branch serverTier isPrimary | branch == thisBranch -> Just (s ^. configuration, (serverTier, isPrimary, s))
              _ -> Nothing
          GhPrDeployment _prId -> flip mapMaybe (cfg ^. serverSection)
            $ \s -> case s ^. deploySection of
              OnPullRequest prTier -> Just (s ^. configuration, (prTier, False, s))
              _ -> Nothing
    -- A single-deployment redeploy (Servers-page "Redeploy" with "only this
    -- deployment" checked) restricts the rollout to one package and leaves the
    -- repo's other running deployments untouched. The target is persisted
    -- per-commit by the redeploy trigger (Garnix.API.Hosts -> Orchestrator).
    mDeployTarget <-
      DB.getManualDeployTarget
        (commitInfo ^. repoInfo . ghRepoOwner)
        (commitInfo ^. repoInfo . ghRepoName)
        (commitInfo ^. commit)
    let wantedPackagesMapping = case mDeployTarget of
          Just pkg -> Map.filterWithKey (\k _ -> k == pkg) fullWantedPackagesMapping
          Nothing -> fullWantedPackagesMapping
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

    wantedServers <-
      wantedBuilds
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
                      exposeSSH = _serverSectionExposeSSH section,
                      authorizeDeployerGithubKeys = _serverSectionAuthorizeDeployerGithubKeys section,
                      authorizedSSHKeys = _serverSectionAuthorizedSSHKeys section,
                      httpPorts,
                      tcpPorts,
                      domains = _serverSectionDomains section,
                      logFile = getServerLogFile <$> _serverSectionLogFile section
                    }
              Nothing -> throw $ OtherError "impossible: wantedPackagesMap should contain all deployable packages"
          )
    let toRedeploy =
          [ (server, wanted)
            | server <- existing,
              wanted <- wantedServers,
              server ^. buildPersistenceName == wanted ^. #build . persistenceName,
              isJust (wanted ^. #build . persistenceName)
          ]
        -- In single-deployment mode never stop the repo's other deployments:
        -- only the targeted package is (re)deployed; everything else stays put.
        toSpinDown
          | isJust mDeployTarget = []
          | otherwise = filter (`notElem` (fst <$> toRedeploy)) existing
        redeployBuilds = map (^. #build) (snd <$> toRedeploy)
        toSpinUp = filter ((`notElem` redeployBuilds) . (^. #build)) wantedServers
    Domains.validateServerDomainsExcept
      (map (^. id) (fst <$> toRedeploy))
      (concatMap (^. #domains) wantedServers)
    let plan = DeployPlan toSpinDown toSpinUp toRedeploy
    unless (null wantedServers) $ do
      checkDeployPlan (commitInfo ^. repoInfo) deploymentType plan
    pure plan

-- | Will catch all exceptions, create a new reporter to report the error to the user and rethrow.
withErrorReporter :: Reporter -> CommitInfo -> M a -> M a
withErrorReporter reporter commitInfo action = do
  checkResult <- try action
  case checkResult of
    Left error -> do
      run <- DB.newRun "deployment plan" commitInfo
      -- withRunReporter carries the shared pending->running-on-first-output
      -- logic that every run kind follows.
      withRunReporter reporter (ReportRun run) $ \runReporter -> do
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
  let builds =
        fmap (^. #build) (plan ^. #toSpinUp)
          <> fmap (^. #build) (snd <$> plan ^. #toRedeploy)
  checkSubdomainValidity repoInfo deploymentType builds
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
  let builds =
        plan
          ^.. #toSpinUp
          . each
          . #build
          <> fmap (^. #build) (snd <$> plan ^. #toRedeploy)
  forM_ builds $ \build -> do
    let packageName = getPackageName $ build ^. package
    case build ^. status of
      Just Success -> pure ()
      -- A skipped dependency is non-blocking (success for dependents).
      Just Skipped -> pure ()
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
    -- New candidates are not committed ready until every concurrent start has
    -- succeeded. If any start fails (and cancels its siblings), compensate all
    -- unready claims immediately; the old generation remains untouched.
    serverInfos <-
      Async.mapConcurrently (startServer reporter commitInfo deploymentType) wantedServers
        `whenErrorEither` const (void cleanupUnreadyServers)
    redeployedServers <- Async.mapConcurrently (uncurry (redeployServer reporter commitInfo deploymentType)) redeployServers
    deployedServerInfos <- toggleServerFlags serverInfos currentServers <?> "Toggling servers ready flags."
    Async.mapConcurrently_ (\s -> stopServer (s ^. id) (s ^. provisionedServerId)) currentServers
    return (deployedServerInfos <> redeployedServers)

stopServer :: ServerId -> ProvisionedServerId -> M ()
stopServer serverId provisionerId = do
  ServerLogStream.stopServerLogStream serverId
  deleteServer provisionerId
  DB.deleteServerDB serverId

-- | Compensating transaction for a process death after a pool guest was
-- claimed but before deployment committed ready_at. Recovery later reruns the
-- deploy plan and claims a clean guest; retaining the half-mutated one would
-- leak both the VM and any partially installed credentials/exposure.
cleanupUnreadyServers :: M Int
cleanupUnreadyServers = do
  unready <- DB.getUnreadyServers
  cleaned <- forM unready $ \server ->
    catchEither
      (stopServer (server ^. id) (server ^. provisionedServerId) $> 1)
      ( \error -> do
          log Error
            $ "cleanupUnreadyServers: failed to remove unready server "
            <> show (server ^. id)
            <> ": "
            <> either show showDebug error
          pure 0
      )
  pure (sum cleaned)

-- | Fail closed before dropping garnix's own OIDC credentials onto a guest.
-- @authentik: default@ shares garnix's shared OIDC client_id/client_secret with
-- the deployed server, so it is allowed only when (1) the deployment is not a PR
-- from an external fork — fork-controlled code must never receive those
-- credentials — and (2) an admin has approved the repo for default-OIDC hosting
-- on the Configure page. Only call this when the server actually requests
-- @authentik: default@; it is a no-op cost otherwise.
requireDefaultAuthentikAllowed :: CommitInfo -> M ()
requireDefaultAuthentikAllowed commitInfo = do
  let authOwner = commitInfo ^. repoInfo . ghRepoOwner
      authRepo = commitInfo ^. repoInfo . ghRepoName
  when (isExternalForkPr authOwner (commitInfo ^. prFromFork))
    $ throw
    $ OtherError
      "`authentik: default` is not allowed for pull requests from external forks (it would expose garnix's OIDC credentials to fork-controlled code). Use a dedicated Authentik app for fork deployments."
  approved <- DB.isDefaultAuthentikApproved authOwner authRepo
  unless approved
    $ throw
    $ OtherError
    $ "This server requests `authentik: default`, which shares garnix's own OIDC login credentials with the deployed guest. An administrator must approve default-OIDC hosting for "
      <> showPretty authOwner
      <> "/"
      <> showPretty authRepo
      <> " on the Configure page before deploying."

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
      let publicHost = publicHostFor domain commitInfo deploymentType (serverToSpinUp ^. #build)
          -- Surface live deploy progress to the run so the UI shows what it is
          -- waiting on (provisioning / booting a guest) instead of a bare
          -- Pending; the first line also flips the run pending -> running.
          reportProgress msg = reportLogs runReporter (mkLogLine msg)
          tierName = serverTierToText (serverToSpinUp ^. #serverTier)
      reportProgress $ "Provisioning " <> getPackageName (serverToSpinUp ^. #build . package) <> " on a " <> tierName <> " guest…"
      serverInfo <- ServerPool.createServer reportProgress (commitInfo ^. repoInfo) deploymentType serverToSpinUp
      reportProgress $ "Guest " <> serverInfo ^. ipv4Addr <> " ready — activating configuration…"
      when (serverToSpinUp ^. #useDefaultAuthentik)
        $ requireDefaultAuthentikAllowed commitInfo
      if serverToSpinUp ^. #useDefaultAuthentik
        then copyDefaultAuthentikEnv (SshUser "root") serverInfo publicHost <?> "Copying default Authentik credentials"
        else removeRuntimeFile (SshUser "root") serverInfo "/var/garnix/keys/default-authentik.env" <?> "Removing stale default Authentik credentials"
      -- Authorize login as the garnix user only when the user opts in, via the
      -- deployer's forge keys and/or explicit authorizedSSHKeys. Otherwise the
      -- garnix user stays login-closed (deploys still work via the hosting key).
      let authorizesGarnixUser =
            serverToSpinUp
              ^. #authorizeDeployerGithubKeys
              || not (null (serverToSpinUp ^. #authorizedSSHKeys))
      copyAuthorizedKeys
        (SshUser "root")
        (commitInfo ^. repoInfo . forge)
        serverInfo
        (if serverToSpinUp ^. #authorizeDeployerGithubKeys then Just (commitInfo ^. reqUser) else Nothing)
        (serverToSpinUp ^. #authorizedSSHKeys)
        <?> "Synchronizing SSH keys"
      -- Public port exposure (DNAT) only makes sense with the local
      -- provisioner; persist whatever it (plus the http routers) exposes, but
      -- only when the server actually declares ssh/ports.
      let wantsExposure =
            serverToSpinUp
              ^. #exposeSSH
              || not (null (serverToSpinUp ^. #httpPorts))
              || not (null (serverToSpinUp ^. #tcpPorts))
      exposeResult <- exposeServerPorts serverInfo serverToSpinUp
      when (wantsExposure || isJust exposeResult) $ do
        DB.setServerExposed (serverInfo ^. id) (exposedBlob serverToSpinUp authorizesGarnixUser exposeResult)
      (serverInfo, stderr) <-
        setupServer (commitInfo ^. repoInfo) (serverToSpinUp ^. #build) serverInfo `whenError` \error -> do
          let logs = showPretty (err error)
          DB.appendToServerDeployLog (serverInfo ^. id) logs
          -- If the guest booted but failed to activate, it is still reachable
          -- (teardown runs later), so capture WHY the switch failed.
          case err error of
            ActivationError {} -> captureGuestFailureDiagnostics serverInfo
            _ -> pure ()
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
      captureAndStoreSshUsers serverInfo
      forM_ (serverToSpinUp ^. #logFile) $ \path ->
        ServerLogStream.startServerLogStream (serverInfo ^. id) (serverInfo ^. ipv4Addr) path
      pure serverInfo

redeployServer :: Reporter -> CommitInfo -> DeploymentType -> ServerInfo -> ServerToSpinUp -> M ServerInfo
redeployServer reporter commitInfo deploymentType serverInfo wanted = do
  let build = wanted ^. #build
  withStorePath build "out" $ \case
    Nothing -> throw $ OtherError "Store path is missing"
    Just storePath -> do
      run <- DB.newRun ("redeployment " <> getPackageName (build ^. package)) commitInfo
      withRunReporter reporter (ReportRun run) $ \runReporter -> do
        sshUser <- chooseRedeploySshUser serverInfo
        domain <- view #hostingDomain
        let publicHost = publicHostFor domain commitInfo deploymentType build
            authorizesGarnixUser =
              wanted
                ^. #authorizeDeployerGithubKeys
                || not (null (wanted ^. #authorizedSSHKeys))
        -- /var/garnix/keys is a tmpfs on the guest (see guest-profile.nix), so
        -- every tmpfs-backed runtime file is converged before activation. Old
        -- guests that predate garnix-user hosting-key access fall back to the
        -- root migration path once; the new configuration restores garnix.
        copyKeys sshUser (commitInfo ^. repoInfo) serverInfo <?> "Copying repo key"
        copyTerminalCa sshUser serverInfo <?> "Copying terminal CA public key"
        copyTerminalPrincipals sshUser serverInfo <?> "Copying terminal principals file"
        copyStatsEnv sshUser serverInfo <?> "Copying guest stats configuration"
        when (wanted ^. #useDefaultAuthentik)
          $ requireDefaultAuthentikAllowed commitInfo
        if wanted ^. #useDefaultAuthentik
          then copyDefaultAuthentikEnv sshUser serverInfo publicHost <?> "Copying default Authentik credentials"
          else removeRuntimeFile sshUser serverInfo "/var/garnix/keys/default-authentik.env" <?> "Removing stale default Authentik credentials"
        copyAuthorizedKeys
          sshUser
          (commitInfo ^. repoInfo . forge)
          serverInfo
          (if wanted ^. #authorizeDeployerGithubKeys then Just (commitInfo ^. reqUser) else Nothing)
          (wanted ^. #authorizedSSHKeys)
          <?> "Synchronizing SSH keys"
        exposeResult <- exposeServerPorts serverInfo wanted
        DB.setServerExposed (serverInfo ^. id) (exposedBlob wanted authorizesGarnixUser exposeResult)
        DB.setServerDomains (serverInfo ^. id) (wanted ^. #domains)
        copyClosure sshUser serverInfo storePath <?> "Copying closure for redeployment"
        deploymentLogs <-
          (switchToConfiguration sshUser serverInfo storePath <?> "Switching to redeployment configuration")
            `whenError` \error -> case err error of
              ActivationError {} -> captureGuestFailureDiagnostics serverInfo
              _ -> pure ()
        now <- liftIO getCurrentTime
        let serverInfo' =
              serverInfo
                & configurationBuildId
                .~ build
                ^. id
                & readyAt
                ?~ now
                & isPrimary
                .~ (wanted ^. #domainIsPrimary)
        DB.updateServerPostDeploy serverInfo' <?> "Updating DB about the redeployed server"
        -- Change the persisted collector target only after activation commits.
        -- A failed redeploy must continue following the previous service log,
        -- including after a backend restart.
        DB.setServerLogFile (serverInfo ^. id) (wanted ^. #logFile)
        captureAndStoreSshUsers serverInfo'
        case wanted ^. #logFile of
          Just path -> ServerLogStream.startServerLogStream (serverInfo' ^. id) (serverInfo' ^. ipv4Addr) path
          Nothing -> ServerLogStream.forgetServerLogStream (serverInfo' ^. id)
        let logs =
              T.unlines
                [ "Server has been successfully redeployed to: https://"
                    <> publicHost,
                  "ipv4: " <> serverInfo ^. ipv4Addr,
                  "ipv6: " <> serverInfo ^. ipv6Addr,
                  "",
                  "logs:"
                    <> deploymentLogs
                ]
        reportLogs runReporter (mkLogLine logs)
        reportComplete runReporter RunReportStatusSuccess
        pure serverInfo'

publicHostFor :: Text -> CommitInfo -> DeploymentType -> Build -> Text
publicHostFor domain commitInfo deploymentType build =
  getPackageName (build ^. package)
    <> "."
    <> fromDeploymentType getBranch (("pull-" <>) . show . getGhPullRequestId) deploymentType
    <> "."
    <> getGhRepoName (commitInfo ^. repoInfo . ghRepoName)
    <> "."
    <> getGhLogin (getGhRepoOwner (commitInfo ^. repoInfo . ghRepoOwner))
    <> "."
    <> domain

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
        copyKeys (SshUser "root") repoInfo serverInfo
        copyTerminalCa (SshUser "root") serverInfo <?> "Copying terminal CA public key"
        copyTerminalPrincipals (SshUser "root") serverInfo <?> "Copying terminal principals file"
        copyStatsEnv (SshUser "root") serverInfo <?> "Copying guest stats configuration"
        copyClosure (SshUser "root") serverInfo storePath <?> "Copying closure"
        stderr <- switchToConfiguration (SshUser "root") serverInfo storePath <?> "Switching to configuration"
        return (serverInfo, stderr)

newtype SshUser = SshUser Text
  deriving stock (Eq, Show)

-- | Prefer the least-privileged deploy user, but retain the hosting-key root
-- path as a compatibility bridge for guests created before garnix-user SSH
-- access was part of the base image.
chooseRedeploySshUser :: ServerInfo -> M SshUser
chooseRedeploySshUser server = do
  garnixWorks <- canConnect (SshUser "garnix")
  if garnixWorks
    then pure (SshUser "garnix")
    else do
      rootWorks <- canConnect (SshUser "root")
      if rootWorks
        then pure (SshUser "root")
        else throw $ ProvisioningError "Neither garnix nor root hosting-key SSH access works for persistent redeployment"
  where
    canConnect (SshUser user) = do
      (ip, sshArgs) <- ServerPool.sshArgsFor server
      (exitCode, _, _) <-
        liftIO
          $ Proc.readProcessWithExitCode
            "ssh"
            ((cs <$> sshArgs) <> [cs user <> "@" <> cs ip, "true"])
            ""
      pure (exitCode == ExitSuccess)

copyClosure :: SshUser -> ServerInfo -> StorePath -> M ()
copyClosure (SshUser user) server storePath = do
  (ip, sshArgs) <- ServerPool.sshArgsFor server
  retryingFor (fromMinutes @Int 1) $ do
    runSubProcess
      $ cmd "nix-copy-closure"
      & addArgs ["--to", user <> "@" <> ip, cs storePath]
      & modifyEnvVar "NIX_SSHOPTS" (const $ Just $ cs $ T.intercalate " " sshArgs)

copyKeys :: SshUser -> RepoInfo -> ServerInfo -> M ()
copyKeys (SshUser user) repoInfo server = do
  (ip, sshArgs) <- ServerPool.sshArgsFor server
  let keyLocation = "/var/garnix/keys/repo-key"
  let sudoArgs = if user == "root" then [] else ["sudo", "-n"]
  let doRemotely args =
        runSubProcess
          $ Cradle.cmd "ssh"
          & addArgs (sshArgs <> [user <> "@" <> cs ip] <> sudoArgs <> args)
  doRemotely ["mkdir", "-p", cs (takeDirectory keyLocation)]
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
              sshArgs,
              sshUser = user,
              sshSudo = user /= "root"
            }
          repoSecretsKey
      )
      <?> "Export private keys to server"
  whenIs _Left exportResult $ throw . ProvisioningError
  doRemotely ["chmod", "400", cs keyLocation]

copyTerminalCa :: SshUser -> ServerInfo -> M ()
copyTerminalCa (SshUser user) server = do
  (ip, sshArgs) <- ServerPool.sshArgsFor server
  terminalCaKey <- view #sshTerminalCaKey
  publicKey <-
    liftIO (deriveSshPublicKey terminalCaKey)
      >>= either (throw . ProvisioningError) pure
  installResult <-
    liftIO
      $ installPublicFile
      $ InstallPublicFileOpts
        { installPublicFileContents = publicKey,
          installPublicFileIpAddr = ip,
          installPublicFileTargetPath = "/var/lib/garnix/terminal-ca.pub",
          installPublicFileSshOptions = sshArgs,
          installPublicFileSshUser = user,
          installPublicFileSshSudo = user /= "root"
        }
  either (throw . ProvisioningError) pure installResult

-- | Install the file that lets THIS guest pin terminal certs to itself, not
-- just to the login user. 'Garnix.API.Terminal.signingArgs' signs every
-- session cert with two principals, @\<loginUser\>,server-\<hash\>@; sshd's
-- default check (used absent an @AuthorizedPrincipalsFile@) only matches the
-- login-user principal against the local username, so a cert minted for
-- server A also authenticates as the same-named user on server B. Setting
-- @AuthorizedPrincipalsFile@ in guest-profile.nix closes that: it replaces
-- sshd's default check with "the cert must carry a principal listed in this
-- file", and this file lists exactly one line, @server-\<hash\>@, computed the
-- SAME way as 'Garnix.API.Terminal.ttServerIdText'
-- (@getHashId . getServerId@) for THIS server — so a cert minted for another
-- server is rejected here even if it names a valid login user. Delivered
-- before every activation that can (re)apply the directive, exactly like
-- 'copyTerminalCa', so the file is always in place first.
copyTerminalPrincipals :: SshUser -> ServerInfo -> M ()
copyTerminalPrincipals (SshUser user) server = do
  (ip, sshArgs) <- ServerPool.sshArgsFor server
  let serverHash = getHashId (getServerId (server ^. id))
  installResult <-
    liftIO
      $ installPublicFile
      $ InstallPublicFileOpts
        { installPublicFileContents = "server-" <> serverHash,
          installPublicFileIpAddr = ip,
          installPublicFileTargetPath = "/var/lib/garnix/terminal-principals",
          installPublicFileSshOptions = sshArgs,
          installPublicFileSshUser = user,
          installPublicFileSshSudo = user /= "root"
        }
  either (throw . ProvisioningError) pure installResult

-- | Install the non-secret stats endpoint/id after claim and before every
-- activation. Existing claimed guests refresh the durable file on redeploy, so
-- endpoint changes do not require destructive VM recreation.
copyStatsEnv :: SshUser -> ServerInfo -> M ()
copyStatsEnv (SshUser user) server = do
  endpoint <- view #statsReportUrl
  (ip, sshArgs) <- ServerPool.sshArgsFor server
  installResult <-
    liftIO
      $ installPublicFile
      $ InstallPublicFileOpts
        { installPublicFileContents = statsEnvContents endpoint (server ^. provisionedServerId),
          installPublicFileIpAddr = ip,
          installPublicFileTargetPath = "/var/lib/garnix/stats.env",
          installPublicFileSshOptions = sshArgs,
          installPublicFileSshUser = user,
          installPublicFileSshSudo = user /= "root"
        }
  either (throw . ProvisioningError) pure installResult

statsEnvContents :: Text -> ProvisionedServerId -> Text
statsEnvContents endpoint provisionerId =
  T.unlines
    [ "GARNIX_STATS_URL=" <> endpoint,
      "GARNIX_PROVISIONER_ID=" <> show (getProvisionedServerId provisionerId)
    ]

-- | Drop garnix's own OIDC client credentials onto a guest that opted in via
-- garnix.yaml (servers[].authentik = "default"). Written as oauth2-proxy env
-- vars to /var/garnix/keys/default-authentik.env (root-only), consumed by the
-- garnix-authentik guest module's mode = "default". Delivered over ssh stdin
-- so the secret never lands in process args or the store.
copyDefaultAuthentikEnv :: SshUser -> ServerInfo -> Text -> M ()
copyDefaultAuthentikEnv (SshUser user) server publicHost = do
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
        ( (cs <$> sshArgs)
            <> [ cs user <> "@" <> cs ip,
                 remoteAsRoot user
                   $ "umask 077 && mkdir -p /var/garnix/keys && cat > "
                   <> envLocation
                   <> " && chmod 400 "
                   <> envLocation
               ]
        )
        (cs contents)
  case exitCode of
    ExitSuccess -> pure ()
    ExitFailure _ -> throw $ OtherError "Exporting default Authentik credentials to the server failed"

-- | Authorize login as the guest's `garnix` user by dropping an authorized_keys
-- file the guest profile reads via authorizedKeys.keyFiles. Keys are the
-- deployer's forge keys (best-effort, only when a deployer is given) plus the
-- explicit authorizedSSHKeys. No-op with no keys.
copyAuthorizedKeys :: SshUser -> Forge -> ServerInfo -> Maybe GhLogin -> [Text] -> M ()
copyAuthorizedKeys (SshUser user) forge' server mDeployer extraKeys = do
  forgeKeys <- maybe (pure []) (fetchDeployerKeys forge') mDeployer
  let keys = filter (not . T.null . T.strip) (forgeKeys <> extraKeys)
  if null keys
    then removeRuntimeFile (SshUser user) server "/var/garnix/keys/authorized_keys"
    else do
      (ip, sshArgs) <- ServerPool.sshArgsFor server
      let keyFile = "/var/garnix/keys/authorized_keys" :: Text
      (exitCode, _, _) <-
        liftIO
          $ Proc.readProcessWithExitCode
            "ssh"
            ( (cs <$> sshArgs)
                <> [ cs user <> "@" <> cs ip,
                     remoteAsRoot user
                       $ "mkdir -p /var/garnix/keys && cat > "
                       <> keyFile
                       <> " && chmod 444 "
                       <> keyFile
                   ]
            )
            (cs (T.unlines keys))
      case exitCode of
        ExitSuccess -> pure ()
        ExitFailure _ -> throw $ OtherError "Writing authorized_keys to the server failed"

-- | Remove a no-longer-declared tmpfs credential. Redeploy is convergence,
-- not an additive copy: otherwise revoking Authentik or SSH-key access in
-- garnix.yaml leaves the old credential live until a power cycle.
removeRuntimeFile :: SshUser -> ServerInfo -> Text -> M ()
removeRuntimeFile (SshUser user) server path = do
  (ip, sshArgs) <- ServerPool.sshArgsFor server
  (exitCode, _, _) <-
    liftIO
      $ Proc.readProcessWithExitCode
        "ssh"
        ((cs <$> sshArgs) <> [cs user <> "@" <> cs ip, remoteAsRoot user ("rm -f " <> path)])
        ""
  case exitCode of
    ExitSuccess -> pure ()
    ExitFailure _ -> throw $ OtherError "Removing stale runtime credential from the server failed"

remoteAsRoot :: Text -> Text -> String
remoteAsRoot user command
  | user == "root" = cs command
  | otherwise = cs $ "sudo -n sh -c '" <> command <> "'"

-- | The deployer's public SSH keys, via the forge's @<login>.keys@ endpoint —
-- github.com for GitHub repos, the configured Gitea instance for Gitea repos
-- (both forges serve the same URL shape). Best-effort: any failure (network,
-- 404, a Gitea with REQUIRE_SIGNIN_VIEW, missing Gitea config) yields no keys.
fetchDeployerKeys :: Forge -> GhLogin -> M [Text]
fetchDeployerKeys forge' login =
  ( do
      mBaseUrl <- case forge' of
        ForgeGithub -> pure $ Just "https://github.com"
        ForgeGitea -> fmap _giteaConfigBaseUrl <$> view #giteaConfig
      case mBaseUrl of
        Nothing -> pure []
        Just baseUrl -> do
          resp <-
            withWreqOptions $ \opts ->
              Wreq.getWith opts (cs (baseUrl <> "/" <> getGhLogin login <> ".keys"))
          pure $ filter (not . T.null . T.strip) $ T.lines $ cs (resp ^. Wreq.responseBody)
  )
    `catchAny` const (pure [])

-- | Converge local SSH/tcp exposure. Sending an empty request is deliberate:
-- it removes stale DNAT rules when a persistent server's config revokes its
-- last exposed port. Returns Nothing only when no local provisioner exists.
exposeServerPorts :: ServerInfo -> ServerToSpinUp -> M (Maybe ExposeResult)
exposeServerPorts server serverToSpinUp = do
  socket <- view #provisionerSocket
  let exposeSSH' = serverToSpinUp ^. #exposeSSH
      tcpGuestPorts = snd <$> serverToSpinUp ^. #tcpPorts
  case socket of
    Just sock -> Just <$> exposeServer sock (_serverInfoProvisionedServerId server) exposeSSH' tcpGuestPorts
    _ -> pure Nothing

-- | The per-server exposure blob stored in servers.exposed:
-- @{"ssh_port": Int|null, "ssh_user": Text|null, "tcp": [...], "http": [...]}@.
-- @ssh_user@ is the login user garnix authorized (currently always @garnix@),
-- or null when only the user's own declared guest users can log in.
exposedBlob :: ServerToSpinUp -> Bool -> Maybe ExposeResult -> Aeson.Value
exposedBlob serverToSpinUp authorizesGarnixUser exposeResult =
  Aeson.object
    [ "ssh_port" Aeson..= (exposeResult >>= _exposeResultSshPort),
      "ssh_user" Aeson..= (if authorizesGarnixUser then Just ("garnix" :: Text) else Nothing),
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

-- | Best-effort: read the guest's real login accounts (via @getent passwd@,
-- over the same garnix-user ssh path 'switchToConfiguration' already uses to
-- switch configuration) and store them on the server row, so the web
-- terminal's "Login as" picker can suggest them. Never fails the deploy —
-- any error capturing/storing is logged and swallowed.
--
-- Uses 'catchEither' (not plain 'catchAny') because 'runSubProcess' signals a
-- non-zero ssh/getent exit via 'throwError' (a 'MonadError' failure inside
-- the ExceptT stack), not a thrown 'SomeException'; 'catchAny' alone would
-- miss it and let the failure propagate into the deploy.
captureAndStoreSshUsers :: ServerInfo -> M ()
captureAndStoreSshUsers server =
  capture `catchEither` \e ->
    log Informational
      $ "captureAndStoreSshUsers: best-effort capture of guest login users failed for server "
      <> show (server ^. id)
      <> ": "
      <> either show show e
  where
    capture = do
      (ip, sshArgs) <- ServerPool.sshArgsFor server
      StdoutUntrimmed output <-
        runSubProcess
          $ cmd "ssh"
          & addArgs (sshArgs <> ["garnix@" <> ip, "getent passwd"])
      DB.setServerSshUsers (server ^. id) (parseLoginUsers output)

-- | Best-effort: when activation fails the guest is still up (its teardown runs
-- later), so pull the guest's failed-unit list and recent warning+ journal (as
-- root over the hosting key) into the server's deploy log. @switch-to-configuration@
-- only reports "the following units failed: <unit>", never WHY; this surfaces the
-- actual cause (e.g. a service that couldn't start) in the run's deploy logs.
-- Never fails the deploy: any ssh/journal error is logged and swallowed.
captureGuestFailureDiagnostics :: ServerInfo -> M ()
captureGuestFailureDiagnostics server =
  capture `catchEither` \e ->
    log Informational
      $ "captureGuestFailureDiagnostics: best-effort guest diagnostics failed for server "
      <> show (server ^. id)
      <> ": "
      <> either show show e
  where
    capture = do
      (ip, sshArgs) <- ServerPool.sshArgsFor server
      StdoutUntrimmed output <-
        runSubProcess
          $ cmd "ssh"
          & addArgs (sshArgs <> ["root@" <> ip, diagCmd])
      DB.appendToServerDeployLog (server ^. id)
        $ "\n=== guest diagnostics ("
        <> ip
        <> ") ===\n"
        <> cs output
    diagCmd =
      "echo '--- failed units ---'; "
        <> "systemctl --failed --no-legend --plain 2>/dev/null; "
        <> "echo; echo '--- journal since boot (warning and above), tail ---'; "
        <> "journalctl -b --no-pager -p warning -o short-precise 2>/dev/null | tail -150"

-- | Parse @getent passwd@ output (@name:passwd:uid:gid:gecos:home:shell@ per
-- line) into login usernames, dropping service/system accounts whose shell
-- ends in @nologin@ or @false@. Deduplicated, first-occurrence order
-- preserved, capped to a sane maximum so a pathological guest can't blow up
-- the servers row. @garnix@ is always included when present, regardless of
-- its shell, since it's the deploy account and always a valid login.
parseLoginUsers :: Text -> [Text]
parseLoginUsers raw =
  take maxCapturedSshUsers $ nubOrd (shellUsers <> garnixIfPresent)
  where
    maxCapturedSshUsers = 50 :: Int
    entries = map (T.splitOn ":") (T.lines raw)
    shellUsers = mapMaybe loginUser entries
    garnixIfPresent = ["garnix" | any ((== Just "garnix") . listToMaybe) entries]
    loginUser fields = case fields of
      (name : _ : _ : _ : _ : _ : shell : _)
        | name /= "root" && not (hasNologinShell shell) -> Just name
      _ -> Nothing
    hasNologinShell shell =
      "nologin" `T.isSuffixOf` shell || "false" `T.isSuffixOf` shell
