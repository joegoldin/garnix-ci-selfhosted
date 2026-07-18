module Garnix.API.Hosts
  ( getHostsForTraefik,
    postHostsHeartbeat,
    postHostsStats,
    hostsAPI,
    HostsAPI,
    getHosts,
    HostList (..),
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Lens (key, values, _Integer, _String)
import Data.Functor ((<&>))
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text qualified as T
import Garnix.DB qualified as DB
import Garnix.GithubInterface.Types
import Garnix.Hosting.Deploy (stopServer)
import Garnix.Hosting.Helpers
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import Servant.Auth.Server

data HostsAPI route = HostsAPI
  { _hostsAPIGetHostsForTraefik :: route :- "traefik" :> Get '[JSON] HostList,
    _hostsAPIHeartbeat :: route :- "heartbeat" :> ReqBody '[JSON] [Text] :> Post '[JSON] NoContent,
    -- | Deployed guests push their own resource samples here (CPU %, memory
    -- used/total). Unauthenticated like the heartbeat: the guest identifies
    -- itself by the provisioner id injected into it at create time. The Caddy
    -- gate must expose /api/hosts/stats ungated (like /api/keys/*) so the
    -- guest can reach it over the public API domain — see the provisioner's
    -- statsReportUrl option.
    _hostsAPIPostStats :: route :- "stats" :> ReqBody '[JSON] HostStatsReport :> Post '[JSON] NoContent,
    _hostsAPIGetIPsForDns :: route :- "dns" :> Get '[JSON] DnsHosts,
    _hostsAPIGetDomainsForOnDemandResolver :: route :- "on-demand-resolver" :> Get '[JSON] OnDemandResolverDomainNames,
    -- | Caddy on_demand_tls "ask" contract: 200 iff the queried domain is a
    -- currently-valid deployed-server domain, 404 otherwise.
    _hostsAPIOnDemandCheck :: route :- "on-demand-check" :> QueryParam "domain" Text :> Get '[JSON] NoContent,
    _hostsAPIGetHosts :: route :- Auth '[JWT, Cookie] AuthJwtPayload :> Get '[JSON] [RunningServer],
    _hostsAPIDeleteHost :: route :- Auth '[JWT, Cookie] AuthJwtPayload :> Capture "serverId" ServerId :> Delete '[JSON] (),
    -- | Current sample + the short rolling window of samples for one server,
    -- for the per-server Monitor page. Auth + ownership-gated the same way as
    -- GET /api/hosts.
    _hostsAPIGetServerStats :: route :- Auth '[JWT, Cookie] AuthJwtPayload :> Capture "serverId" ServerId :> "stats" :> Get '[JSON] ServerStatsHistory
  }
  deriving (Generic)

hostsAPI :: HostsAPI (AsServerT M)
hostsAPI =
  HostsAPI
    { _hostsAPIGetHostsForTraefik = getHostsForTraefik,
      _hostsAPIHeartbeat = postHostsHeartbeat,
      _hostsAPIPostStats = postHostsStats,
      _hostsAPIGetIPsForDns = getHostsForDns,
      _hostsAPIGetDomainsForOnDemandResolver = getDomainsForOnDemandResolver,
      _hostsAPIOnDemandCheck = onDemandCheck,
      _hostsAPIGetHosts = getHosts,
      _hostsAPIDeleteHost = deleteHost,
      _hostsAPIGetServerStats = getServerStats
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

-- | Ingest a resource sample pushed by a deployed guest. Best-effort: an
-- unmatched provisioner id (guest not yet claimed, or server deleted) is
-- silently dropped by 'DB.upsertServerStats'.
postHostsStats :: HostStatsReport -> M NoContent
postHostsStats report = NoContent <$ DB.upsertServerStats report

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

onDemandCheck :: Maybe Text -> M NoContent
onDemandCheck mDomain = do
  OnDemandResolverDomainNames names <- getDomainsForOnDemandResolver
  case mDomain of
    Just d | d `elem` names -> pure NoContent
    _ -> throw NotFound

hostToPrimaryDomainName :: Host -> Text
hostToPrimaryDomainName host =
  getGhRepoName (_hostRepoName host)
    <> "."
    <> getGhLogin (getGhRepoOwner (_hostRepoOwner host))
