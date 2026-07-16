module Garnix.API.Hosts
  ( getHostsForTraefik,
    postHostsHeartbeat,
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
    _hostsAPIGetIPsForDns :: route :- "dns" :> Get '[JSON] DnsHosts,
    _hostsAPIGetDomainsForOnDemandResolver :: route :- "on-demand-resolver" :> Get '[JSON] OnDemandResolverDomainNames,
    -- | Caddy on_demand_tls "ask" contract: 200 iff the queried domain is a
    -- currently-valid deployed-server domain, 404 otherwise.
    _hostsAPIOnDemandCheck :: route :- "on-demand-check" :> QueryParam "domain" Text :> Get '[JSON] NoContent,
    _hostsAPIGetHosts :: route :- Auth '[JWT, Cookie] AuthJwtPayload :> Get '[JSON] [RunningServer],
    _hostsAPIDeleteHost :: route :- Auth '[JWT, Cookie] AuthJwtPayload :> Capture "serverId" ServerId :> Delete '[JSON] ()
  }
  deriving (Generic)

hostsAPI :: HostsAPI (AsServerT M)
hostsAPI =
  HostsAPI
    { _hostsAPIGetHostsForTraefik = getHostsForTraefik,
      _hostsAPIHeartbeat = postHostsHeartbeat,
      _hostsAPIGetIPsForDns = getHostsForDns,
      _hostsAPIGetDomainsForOnDemandResolver = getDomainsForOnDemandResolver,
      _hostsAPIOnDemandCheck = onDemandCheck,
      _hostsAPIGetHosts = getHosts,
      _hostsAPIDeleteHost = deleteHost
    }

data HostList = HostList
  { hostList :: [Host],
    hostBaseUrl :: Text,
    -- | Base domain for deployed servers (Env.hostingDomain).
    hostDomain :: Text,
    -- | Per-server extra http ports (name, guest port), by server id, from
    -- garnix.yaml servers[].ports; each becomes <name>.<server-domain>.
    hostExtraHttpPorts :: [(ServerId, [(Text, Int)])]
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
  toJSON (HostList hosts baseUrl domain extraHttpPorts) =
    let routerMapPair serviceDomain ruleDomain =
          ( ruleDomain,
            [aesonQQ| {
              service: #{serviceDomain},
              rule: #{"Host(`" <> ruleDomain <> "." <> domain <> "`)"},
              middlewares: ["heartbeatmiddleware"]
              }
            |]
          )
        portsFor h = fromMaybe [] (lookup (_hostServerId h) extraHttpPorts)
        -- <name>.<pkg>.<branch>.<repo>.<owner> for an extra http port.
        portDomain h name = name <> "." <> hostToDomainName h

        httpRouters =
          Map.fromList
            $ concatMap
              ( \h ->
                  [routerMapPair (hostToDomainName h) (hostToDomainName h)]
                    <> (if h ^. isPrimary then [routerMapPair (hostToDomainName h) (hostToPrimaryDomainName h)] else [])
                    <> [routerMapPair (portDomain h name) (portDomain h name) | (name, _) <- portsFor h]
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
  extraHttpPorts <- map (\(sid, blob) -> (sid, parseHttpPorts blob)) <$> DB.getServerExposures
  hosts <-
    DB.getAllRunningHosts
      <&> filter
        ( \host ->
            isValidSubdomainString (host ^. repoOwner . to getGhRepoOwner . to getGhLogin)
              && isValidSubdomainString (host ^. repoName . to getGhRepoName)
              && (isValidSubdomainString (host ^. branch . to getBranch) || isJust (host ^. pullRequest))
              && isValidSubdomainString (host ^. packageName . to getPackageName)
        )
  pure $ HostList hosts baseUrl domain extraHttpPorts

postHostsHeartbeat :: [Text] -> M NoContent
postHostsHeartbeat hosts = NoContent <$ DB.upsertHeartbeat hosts

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
  hetznerServerIds <- do
    DB.getHetznerServerById orgs serverId >>= \case
      Nothing -> pure []
      Just serverId -> do
        pure [serverId]
  case hetznerServerIds of
    [hetznerServerId] -> do stopServer serverId hetznerServerId
    _ -> throw NotFound
deleteHost _ _ = throw Unauthorized

data OnDemandResolverDomainNames = OnDemandResolverDomainNames
  { domains :: [Text]
  }
  deriving (Generic, ToJSON)

getDomainsForOnDemandResolver :: M OnDemandResolverDomainNames
getDomainsForOnDemandResolver = do
  domain <- view #hostingDomain
  extraHttpPorts <- map (\(sid, blob) -> (sid, parseHttpPorts blob)) <$> DB.getServerExposures
  runningHosts <- DB.getAllRunningHosts
  let portsFor h = fromMaybe [] (lookup (_hostServerId h) extraHttpPorts)
  pure
    $ OnDemandResolverDomainNames
      { domains =
          concatMap
            ( \host ->
                [hostToDomainName host <> "." <> domain]
                  <> (if host ^. isPrimary then [hostToPrimaryDomainName host <> "." <> domain] else [])
                  <> [name <> "." <> hostToDomainName host <> "." <> domain | (name, _) <- portsFor host]
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
