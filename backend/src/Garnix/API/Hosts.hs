module Garnix.API.Hosts
  ( getHostsForTraefik,
    postHostsHeartbeat,
    postHostsStats,
    postHostsStatsGuarded,
    statsSourceAllowed,
    hostsAPI,
    HostsAPI,
    getHosts,
    HostList (..),
    -- exported for tests (SpecHook clears it between specs)
    __onDemandDomainsCache,
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Lens (key, values, _Integer, _String)
import Data.Functor ((<&>))
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text qualified as T
import Garnix.DB qualified as DB
import Garnix.Duration
import Garnix.ExpiringCache
import Garnix.GithubInterface.Types
import Garnix.Hosting.Deploy (stopServer)
import Garnix.Hosting.Helpers
import Garnix.Hosting.LogStream qualified as ServerLogStream
import Garnix.Monad
import Garnix.Monad.Concurrency (forkM)
import Garnix.Orchestrator qualified as Orchestrator
import Garnix.Prelude
import Garnix.Types
import Network.Socket (SockAddr (..), hostAddress6ToTuple, hostAddressToTuple)
import Servant.API.RemoteHost (RemoteHost)
import Servant.Auth.Server
import System.IO.Unsafe qualified

data HostsAPI route = HostsAPI
  { _hostsAPIGetHostsForTraefik :: route :- "traefik" :> Get '[JSON] HostList,
    _hostsAPIHeartbeat :: route :- "heartbeat" :> ReqBody '[JSON] [Text] :> Post '[JSON] NoContent,
    -- | Deployed guests push their own resource samples here (CPU %, memory
    -- used/total). Unauthenticated like the heartbeat: the guest identifies
    -- itself by the provisioner id the backend installs after claim. The Caddy
    -- gate must expose /api/hosts/stats ungated (like /api/keys/*) so the
    -- guest can reach it over the public API domain. The backend installs the
    -- endpoint/id marker after claiming a pre-warm guest.
    _hostsAPIPostStats :: route :- "stats" :> RemoteHost :> Header "X-Forwarded-For" Text :> ReqBody '[JSON] HostStatsReport :> Post '[JSON] NoContent,
    _hostsAPIGetIPsForDns :: route :- "dns" :> Get '[JSON] DnsHosts,
    _hostsAPIGetDomainsForOnDemandResolver :: route :- "on-demand-resolver" :> Get '[JSON] OnDemandResolverDomainNames,
    -- | Caddy on_demand_tls "ask" contract: 200 iff the queried domain is a
    -- currently-valid deployed-server domain, 404 otherwise.
    _hostsAPIOnDemandCheck :: route :- "on-demand-check" :> QueryParam "domain" Text :> Get '[JSON] NoContent,
    _hostsAPIGetHosts :: route :- Auth '[JWT, Cookie] AuthJwtPayload :> Get '[JSON] [RunningServer],
    _hostsAPIDeleteHost :: route :- Auth '[JWT, Cookie] AuthJwtPayload :> Capture "serverId" ServerId :> Delete '[JSON] (),
    -- | Kick off a fresh build+deploy job for this server's current commit,
    -- re-running the pipeline and redeploying the guest. Auth + ownership-gated
    -- the same way as DELETE / stats. Async: returns immediately.
    _hostsAPIRedeployHost :: route :- Auth '[JWT, Cookie] AuthJwtPayload :> Capture "serverId" ServerId :> "redeploy" :> Post '[JSON] (),
    -- | Current sample + the short rolling window of samples for one server,
    -- for the per-server Monitor page. Auth + ownership-gated the same way as
    -- GET /api/hosts.
    _hostsAPIGetServerStats :: route :- Auth '[JWT, Cookie] AuthJwtPayload :> Capture "serverId" ServerId :> "stats" :> Get '[JSON] ServerStatsHistory,
    -- | Bounded, process-local application log stream collected from the
    -- optional garnix.yaml servers[].logFile over private deploy SSH.
    _hostsAPIGetServerLogs :: route :- Auth '[JWT, Cookie] AuthJwtPayload :> Capture "serverId" ServerId :> "logs" :> Get '[JSON] ServerLogStream.ServerLogSnapshot
  }
  deriving (Generic)

hostsAPI :: HostsAPI (AsServerT M)
hostsAPI =
  HostsAPI
    { _hostsAPIGetHostsForTraefik = getHostsForTraefik,
      _hostsAPIHeartbeat = postHostsHeartbeat,
      _hostsAPIPostStats = postHostsStatsGuarded,
      _hostsAPIGetIPsForDns = getHostsForDns,
      _hostsAPIGetDomainsForOnDemandResolver = getDomainsForOnDemandResolver,
      _hostsAPIOnDemandCheck = onDemandCheck,
      _hostsAPIGetHosts = getHosts,
      _hostsAPIDeleteHost = deleteHost,
      _hostsAPIRedeployHost = redeployHost,
      _hostsAPIGetServerStats = getServerStats,
      _hostsAPIGetServerLogs = getServerLogs
    }

data HostList = HostList
  { hostList :: [Host],
    hostBaseUrl :: Text,
    -- | Base domain for deployed servers (Env.hostingDomain).
    hostDomain :: Text,
    -- | Per-server extra http ports (name, guest port), by server id, from
    -- garnix.yaml servers[].ports; each becomes <name>.<server-domain>.
    hostExtraHttpPorts :: [(ServerId, [(Text, Int)])],
    -- | Per-server declared extra hostnames (garnix.yaml servers[].domains /
    -- the Configure registry), by server id; each becomes a Host(<fqdn>) router.
    hostDeclaredDomains :: [(ServerId, [Text])]
  }
  deriving stock (Eq, Show, Generic)

-- | Extract the http ports ([(name, port)]) from a servers.exposed blob.
parseHttpPorts :: Aeson.Value -> [(Text, Int)]
parseHttpPorts v =
  [ (name, fromIntegral port)
    | entry <- v ^.. key "http" . values,
      name <- toList (entry ^? key "name" . _String),
      port <- toList (entry ^? key "port" . _Integer)
  ]

instance ToJSON HostList where
  toJSON (HostList hosts baseUrl domain extraHttpPorts declaredDomains) =
    let routerMapPair serviceDomain ruleDomain =
          ( ruleDomain,
            [aesonQQ| {
              service: #{serviceDomain},
              rule: #{"Host(`" <> ruleDomain <> "." <> domain <> "`)"},
              middlewares: ["heartbeatmiddleware"]
              }
            |]
          )
        -- A router whose rule is the full FQDN verbatim (a declared vanity /
        -- custom domain), not suffixed with the hosting domain. The service is
        -- the guest's own service (already in httpServices below).
        fqdnRouterPair serviceDomain fqdn =
          ( fqdn,
            [aesonQQ| {
              service: #{serviceDomain},
              rule: #{"Host(`" <> fqdn <> "`)"},
              middlewares: ["heartbeatmiddleware"]
              }
            |]
          )
        portsFor h = fromMaybe [] (lookup (_hostServerId h) extraHttpPorts)
        domainsFor h = fromMaybe [] (lookup (_hostServerId h) declaredDomains)
        -- <name>.<pkg>.<branch>.<repo>.<owner> for an extra http port.
        portDomain h name = name <> "." <> hostToDomainName h

        httpRouters =
          Map.fromList
            $ concatMap
              ( \h ->
                  [routerMapPair (hostToDomainName h) (hostToDomainName h)]
                    <> (if h ^. isPrimary then [routerMapPair (hostToDomainName h) (hostToPrimaryDomainName h)] else [])
                    <> [routerMapPair (portDomain h name) (portDomain h name) | (name, _) <- portsFor h]
                    <> [fqdnRouterPair (hostToDomainName h) d | d <- domainsFor h]
              )
              hosts
        serviceForUrl url =
          [aesonQQ|
            { loadBalancer:
                  { servers: [
                     { url: #{url} }
                    ]
                  }
            }
          |]
        httpServices =
          Map.fromList
            $ [(hostToDomainName h, serviceForUrl ("http://" <> _hostIpV4Addr h)) | h <- hosts]
            <> [ (portDomain h name, serviceForUrl ("http://" <> _hostIpV4Addr h <> ":" <> cs (show port)))
                 | h <- hosts,
                   (name, port) <- portsFor h
               ]
     in [aesonQQ|
         {
          http:
             {
              routers: #{httpRouters},
              services: #{httpServices},
              middlewares: {
                heartbeatmiddleware: {
                  plugin: {
                    heartbeatmiddleware: {
                      reportEndpoint: #{baseUrl <> "/api/hosts/heartbeat"}
                    }
                  }
                }
              }
             }
         }
       |]

getHostsForTraefik :: M HostList
getHostsForTraefik = do
  baseUrl <- view #baseUrl
  domain <- view #hostingDomain
  extraHttpPorts <- map (second parseHttpPorts) <$> DB.getServerExposures
  declaredDomains <- DB.getServerDomains
  hosts <-
    DB.getAllRunningHosts
      <&> filter
        ( \host ->
            isValidSubdomainString (host ^. repoOwner . to getGhRepoOwner . to getGhLogin)
              && isValidSubdomainString (host ^. repoName . to getGhRepoName)
              && (isValidSubdomainString (host ^. branch . to getBranch) || isJust (host ^. pullRequest))
              && isValidSubdomainString (host ^. packageName . to getPackageName)
        )
  pure $ HostList hosts baseUrl domain extraHttpPorts declaredDomains

postHostsHeartbeat :: [Text] -> M NoContent
postHostsHeartbeat hosts = NoContent <$ DB.upsertHeartbeat hosts

-- | Ingest a resource sample pushed by a deployed guest. An unmatched
-- provisioner id (server ended/deleted, or the guest orphaned) returns 404
-- rather than a silent 204, so the guest's reporter surfaces the failure (see
-- provisioner/guest-profile.nix) instead of believing its pushes land.
postHostsStats :: HostStatsReport -> M NoContent
postHostsStats report = do
  matched <- DB.upsertServerStats report
  unless matched $ throw NotFound
  pure NoContent

-- | Source gate for guest stats pushes, active in self-host mode only. The
-- backend listens on 127.0.0.1 behind Caddy, so the TCP peer of a proxied
-- request is always loopback; the guest's real address is what Caddy saw,
-- delivered in X-Forwarded-For (Caddy replaces any client-supplied value with
-- the actual peer address, and only Caddy can reach the loopback listener).
-- Accept a sample iff the effective client is in the guest bridge subnet:
-- either the peer itself (a direct bridge listener), or a loopback peer whose
-- X-Forwarded-For client is.
postHostsStatsGuarded :: SockAddr -> Maybe Text -> HostStatsReport -> M NoContent
postHostsStatsGuarded peer mForwardedFor report = do
  selfHost <- view #selfHostMode
  when selfHost $ do
    prefix <- view #guestSubnetPrefix
    unless (statsSourceAllowed prefix peer mForwardedFor)
      $ throw
      $ ForbiddenWithMessage "stats: source address not in the guest subnet"
  postHostsStats report

-- | Pure decision for 'postHostsStatsGuarded'; exported for tests. The
-- forwarded client is the LAST X-Forwarded-For entry — the one appended by
-- the proxy we trust (Caddy strips untrusted inbound values entirely, so in
-- practice it is the only entry).
statsSourceAllowed :: Text -> SockAddr -> Maybe Text -> Bool
statsSourceAllowed guestPrefix peer mForwardedFor =
  inGuestSubnet peerIp || (isLoopback peerIp && inGuestSubnet forwardedClientIp)
  where
    peerIp = sockAddrIPv4 peer
    forwardedClientIp = do
      xff <- mForwardedFor
      listToMaybe (reverse (map T.strip (T.splitOn "," xff)))
    inGuestSubnet = maybe False (guestPrefix `T.isPrefixOf`)
    isLoopback = maybe False ("127." `T.isPrefixOf`)

-- | Render an IPv4 (or IPv4-mapped IPv6) socket address as dotted decimal.
sockAddrIPv4 :: SockAddr -> Maybe Text
sockAddrIPv4 = \case
  SockAddrInet _ addr ->
    let (a, b, c, d) = hostAddressToTuple addr
     in Just $ T.intercalate "." (map (cs . show) [a, b, c, d])
  SockAddrInet6 _ _ addr _ ->
    case hostAddress6ToTuple addr of
      (0, 0, 0, 0, 0, 0xffff, hi, lo) ->
        Just
          $ T.intercalate "."
          $ map (cs . show) [hi `div` 256, hi `mod` 256, lo `div` 256, lo `mod` 256]
      _ -> Nothing
  _ -> Nothing

-- | Current sample + the rolling window of samples for one server, keyed by
-- ServerId. 'current' is the most recent sample; 'samples' is oldest-first.
data ServerStatsHistory = ServerStatsHistory
  { current :: Maybe ServerStatsSample,
    samples :: [ServerStatsSample]
  }
  deriving (Generic, ToJSON)

getServerStats :: AuthResult AuthJwtPayload -> ServerId -> M ServerStatsHistory
getServerStats (Authenticated (WebSession user ghToken)) serverId = do
  servers <-
    getRunningAndRecentServersForOwners
      . (GhRepoOwner (user ^. githubLogin) :)
      . map organizationName
      =<< getInstalledOrgs ghToken
  if any ((== serverId) . _runningServerId) servers
    then do
      samples <- DB.getServerStatsHistory serverId
      pure $ ServerStatsHistory (if null samples then Nothing else Just (last samples)) samples
    else throw NotFound
getServerStats _ _ = throw Unauthorized

getServerLogs :: AuthResult AuthJwtPayload -> ServerId -> M ServerLogStream.ServerLogSnapshot
getServerLogs (Authenticated (WebSession user ghToken)) serverId = do
  servers <-
    getRunningAndRecentServersForOwners
      . (GhRepoOwner (user ^. githubLogin) :)
      . map organizationName
      =<< getInstalledOrgs ghToken
  if any ((== serverId) . _runningServerId) servers
    then do
      configured <- isJust <$> DB.getServerLogFile serverId
      ServerLogStream.getServerLogSnapshot serverId configured
    else throw NotFound
getServerLogs _ _ = throw Unauthorized

data DnsHosts = DnsHosts
  { byHash :: Map Text HostIPs,
    byName :: Map Text HostIPs
  }
  deriving (Generic, ToJSON)

data HostIPs = HostIPs {ipv4 :: Text, ipv6 :: Text}
  deriving (Eq, Show, Generic, ToJSON)

getHostsForDns :: M DnsHosts
getHostsForDns = do
  runningHosts <- DB.getAllRunningHosts
  let mapRunningHosts :: (Host -> Maybe Text) -> Map Text HostIPs
      mapRunningHosts getName =
        Map.fromList
          $ mapMaybe
            ( \host -> do
                name <- getName host
                pure
                  ( name,
                    HostIPs
                      { ipv4 = host ^. ipV4Addr,
                        ipv6 = host ^. ipV6Addr
                      }
                  )
            )
            runningHosts
  let byHash = mapRunningHosts $ \host -> do
        drvPath <- host ^. drvPath
        T.take 32 <$> T.stripPrefix "/nix/store/" (cs drvPath)
  let byName = mapRunningHosts $ Just . hostToDomainName
  pure $ DnsHosts {byHash, byName}

getHosts :: AuthResult AuthJwtPayload -> M [RunningServer]
getHosts (Authenticated (WebSession user ghToken)) = do
  getRunningAndRecentServersForOwners
    . (GhRepoOwner (user ^. githubLogin) :)
    . map organizationName
    =<< getInstalledOrgs ghToken
getHosts _ = throw Unauthorized

deleteHost :: AuthResult AuthJwtPayload -> ServerId -> M ()
deleteHost (Authenticated (WebSession user ghToken)) serverId = do
  orgs <-
    (GhRepoOwner (user ^. githubLogin) :)
      . map organizationName
      <$> getInstalledOrgs ghToken
  provisionedServerIds <- do
    DB.getProvisionerServerById orgs serverId >>= \case
      Nothing -> pure []
      Just serverId -> do
        pure [serverId]
  case provisionedServerIds of
    [provisionedServerId] -> do stopServer serverId provisionedServerId
    _ -> throw NotFound
deleteHost _ _ = throw Unauthorized

-- | Redeploy a server: kick off a FRESH build+deploy job on a new synthetic
-- @manual-<timestamp>@ commit, so it gets its own commit page with a single
-- "eval → build all → deploy once" pass. For a branch deployment this
-- re-evaluates the branch's current HEAD via 'Orchestrator.triggerBranchBuild'
-- (the same primitive as the "Trigger Builds" button). We deliberately do NOT
-- reuse the server's original commit (via 'restartCommit'): that piles the new
-- runs onto the original push's commit page, which reads as a duplicate deploy.
-- PR deployments have no manual-branch trigger, so they fall back to re-running
-- the config's own commit. Same auth + ownership gate as GET
-- /api/hosts/<id>/stats. Async; progress shows on the new commit/run page.
redeployHost :: AuthResult AuthJwtPayload -> ServerId -> M ()
redeployHost (Authenticated (WebSession user ghToken)) serverId = do
  servers <-
    getRunningAndRecentServersForOwners
      . (GhRepoOwner (user ^. githubLogin) :)
      . map organizationName
      =<< getInstalledOrgs ghToken
  case filter ((== serverId) . _runningServerId) servers of
    (server : _) -> do
      build <- DB.getBuild (_runningServerConfigurationBuildId server)
      let owner = _runningServerRepoOwner server
          repo = _runningServerRepoName server
          publicity = build ^. repoIsPublic
      case _runningServerType server of
        BranchDeployment branch ->
          forkM . void $ Orchestrator.triggerBranchBuild (user ^. githubLogin) publicity owner repo branch
        GhPrDeployment _ ->
          forkM $ Orchestrator.restartCommit (user ^. githubLogin) build
    [] -> throw NotFound
redeployHost _ _ = throw Unauthorized

data OnDemandResolverDomainNames = OnDemandResolverDomainNames
  { domains :: [Text]
  }
  deriving (Generic, ToJSON)

getDomainsForOnDemandResolver :: M OnDemandResolverDomainNames
getDomainsForOnDemandResolver = do
  domain <- view #hostingDomain
  extraHttpPorts <- map (second parseHttpPorts) <$> DB.getServerExposures
  declaredDomains <- DB.getServerDomains
  runningHosts <- DB.getAllRunningHosts
  let portsFor h = fromMaybe [] (lookup (_hostServerId h) extraHttpPorts)
      domainsFor h = fromMaybe [] (lookup (_hostServerId h) declaredDomains)
  pure
    $ OnDemandResolverDomainNames
      { domains =
          concatMap
            ( \host ->
                [hostToDomainName host <> "." <> domain]
                  <> (if host ^. isPrimary then [hostToPrimaryDomainName host <> "." <> domain] else [])
                  <> [name <> "." <> hostToDomainName host <> "." <> domain | (name, _) <- portsFor host]
                  <> domainsFor host
            )
            runningHosts
      }

-- | Process-local memo of the routable-domain set for the Caddy on_demand_tls
-- "ask" endpoint. Every unknown-SNI TLS handshake hits 'onDemandCheck', so an
-- SNI flood would otherwise amplify into three DB queries per handshake; the
-- 10s TTL mirrors the on-demand-resolver sidecar's FETCH_INTERVAL
-- (hosting-gateway/on-demand-resolver/src/lib.ts). Module-level
-- (unsafePerformIO + NOINLINE) is the codebase's established cache pattern —
-- see Garnix.API.Cache.Permissions.__getRepoPermissionsCache. Unnamed so a
-- flood doesn't also amplify into per-request cache log lines.
type OnDemandDomainsCache = ExpiringCache () OnDemandResolverDomainNames

{-# NOINLINE __onDemandDomainsCache #-}
__onDemandDomainsCache :: OnDemandDomainsCache
__onDemandDomainsCache =
  System.IO.Unsafe.unsafePerformIO
    $ mkCache Nothing (fromSeconds @Int 10) (fromSeconds @Int 2)

onDemandCheck :: Maybe Text -> M NoContent
onDemandCheck mDomain = do
  OnDemandResolverDomainNames names <-
    lookupCache __onDemandDomainsCache () getDomainsForOnDemandResolver
  case mDomain of
    Just d | d `elem` names -> pure NoContent
    _ -> throw NotFound

hostToPrimaryDomainName :: Host -> Text
hostToPrimaryDomainName host =
  getGhRepoName (_hostRepoName host)
    <> "."
    <> getGhLogin (getGhRepoOwner (_hostRepoOwner host))
