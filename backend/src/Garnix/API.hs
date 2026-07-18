module Garnix.API where

import Autodocodec.Schema (JSONSchema)
import Data.Text qualified as T
import Garnix.API.Account
import Garnix.API.Admin (AdminAPI, adminAPI)
import Garnix.API.Artifacts (ArtifactsAPI, artifactsAPI)
import Garnix.API.Auth
import Garnix.API.Badges
import Garnix.API.Builds
import Garnix.API.Cache
import Garnix.API.Commits
import Garnix.API.ConfigSchema (garnixConfigJsonSchema)
import Garnix.API.Configure (ConfigureAPI, configureAPI)
import Garnix.API.Monitoring (MonitoringAPI, monitoringAPI)
import Garnix.API.Dev (DevAPI, devAPI)
import Garnix.API.GhWebhooks
import Garnix.API.GiteaWebhooks (GiteaWebhookAPI, giteaWebhookAPI)
import Garnix.API.Health
import Garnix.API.Hosts
import Garnix.API.Keys
import Garnix.API.Modules
import Garnix.API.Runs (RunAPI, runAPI)
import Garnix.DB qualified as DB
import Garnix.Hosting.Domains qualified as Domains
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import Servant
import Servant.Auth.Server

type CT = '[JSON]

api :: Proxy (ToServant WholeAPI AsApi)
api = genericApi (Proxy :: Proxy WholeAPI)

data WholeAPI r = WholeAPI
  { events ::
      r
        :- "api"
          :> "events"
          :> ( "github" :> ToServantApi GhWebhookAPI
                 :<|> "gitea" :> ToServantApi GiteaWebhookAPI
             ),
    account :: r :- "api" :> "account" :> Auth '[JWT, Cookie] AuthJwtPayload :> ToServantApi AccountAPI,
    admin :: r :- "api" :> "admin" :> Auth '[JWT, Cookie] AuthJwtPayload :> ToServantApi AdminAPI,
    artifacts :: r :- "api" :> "artifacts" :> Auth '[JWT, Cookie] AuthJwtPayload :> Header "authorization" Text :> ToServantApi ArtifactsAPI,
    configure :: r :- "api" :> "configure" :> Auth '[JWT, Cookie] AuthJwtPayload :> ToServantApi ConfigureAPI,
    monitoring :: r :- "api" :> "monitoring" :> Auth '[JWT, Cookie] AuthJwtPayload :> ToServantApi MonitoringAPI,
    build :: r :- "api" :> "build" :> Auth '[JWT, Cookie] AuthJwtPayload :> ToServantApi BuildAPI,
    commit :: r :- "api" :> "commits" :> Auth '[JWT, Cookie] AuthJwtPayload :> ToServantApi CommitAPI,
    run :: r :- "api" :> "run" :> Auth '[JWT, Cookie] AuthJwtPayload :> ToServantApi RunAPI,
    modules :: r :- "api" :> "modules" :> Auth '[JWT, Cookie] AuthJwtPayload :> ToServantApi ModulesAPI,
    dev :: r :- "api" :> "dev" :> ToServantApi DevAPI,
    hosts :: r :- "api" :> "hosts" :> ToServantApi HostsAPI,
    keys :: r :- "api" :> "keys" :> Capture "owner" GhRepoOwner :> Capture "repo" GhRepoName :> "repo-key.public" :> Get '[PlainText] PublicKey,
    actionKeys :: r :- "api" :> "keys" :> Capture "owner" GhRepoOwner :> Capture "repo" GhRepoName :> "actions" :> Capture "action" PackageName :> "key.public" :> Get '[PlainText] PublicKey,
    login :: r :- "api" :> "login" :> ToServantApi LoginAPI,
    signup :: r :- "api" :> "signup" :> ToServantApi SignupAPI,
    whoami :: r :- "api" :> "whoami" :> Auth '[JWT, Cookie] AuthJwtPayload :> Get '[JSON] (Maybe UserDto),
    authJwt :: r :- "api" :> "auth" :> "jwt" :> ToServantApi AuthJwtAPI,
    config :: r :- "api" :> "config" :> Get '[JSON] FrontendConfig,
    badges :: r :- "api" :> "badges" :> Capture "owner" GhRepoOwner :> Capture "repo" GhRepoName :> QueryParam "branch" Branch :> Get '[JSON] Badge,
    waitlist :: r :- "api" :> "waitlist" :> ReqBody '[JSON] Email :> Post '[JSON] (),
    cache :: r :- "api" :> "cache" :> ToServantApi CacheAPI,
    garnixConfigSchema :: r :- "api" :> "garnix-config-schema.json" :> Get '[JSON] JSONSchema,
    health :: r :- "api" :> "health" :> ToServantApi HealthAPI
  }
  deriving stock (Generic)

data ProjectAPI r = ProjectAPI
  { get ::
      r
        :- Capture "gh_owner" Text
          :> Capture "gh_repo" Text
          :> "commit"
          :> Capture "commit" CommitHash
          :> Get CT (),
    post ::
      r
        :- Capture "gh_owner" Text
          :> Capture "gh_repo" Text
          :> "commit"
          :> Capture "commit" CommitHash
          :> QueryParam "token" GhToken
          :> Post '[JSON] RunResult
  }
  deriving stock (Generic)

wholeAPI :: WholeAPI (AsServerT M)
wholeAPI =
  WholeAPI
    { events = toServant ghWebhookAPI :<|> toServant giteaWebhookAPI,
      account = toServant . accountAPI,
      admin = toServant . adminAPI,
      artifacts = \auth authHeader -> toServant $ artifactsAPI auth authHeader,
      configure = toServant . configureAPI,
      monitoring = toServant . monitoringAPI,
      dev = devAPI,
      login = toServant loginAPI,
      signup = toServant signupAPI,
      whoami = whoAmIAPI,
      authJwt = toServant authJwtAPI,
      hosts = toServant hostsAPI,
      keys = Garnix.API.Keys.getRepoPublicKey,
      actionKeys = Garnix.API.Keys.getActionPublicKey,
      config = getConfig,
      build = toServant . buildAPI,
      commit = toServant . commitAPI,
      run = toServant . runAPI,
      modules = toServant . modulesAPI,
      badges = badgesAPI,
      waitlist = waitlistAPI,
      cache = toServant cacheAPI,
      garnixConfigSchema = pure garnixConfigJsonSchema,
      health = toServant healthAPI
    }

getConfig :: M FrontendConfig
getConfig = do
  ghAppName <- view #githubAppName
  cacheUrl <- view #cacheUrl
  giteaUrl <- maybe "" _giteaConfigBaseUrl <$> view #giteaConfig
  selfHost <- view #selfHostMode
  sshHost <- view #sshHost
  hostingIp <- view #hostingPublicIp
  hostingDomain' <- view #hostingDomain
  hostingBases <- Domains.knownBaseDomains
  pure $ FrontendConfig {_frontendConfigGithubAppName = ghAppName, _frontendConfigCacheUrl = cacheUrl, _frontendConfigGiteaUrl = giteaUrl, _frontendConfigSelfHostMode = selfHost, _frontendConfigSshHost = sshHost, _frontendConfigHostingPublicIp = hostingIp, _frontendConfigHostingDomain = hostingDomain', _frontendConfigHostingBases = hostingBases}

waitlistAPI :: Email -> M ()
waitlistAPI email = do
  let isValid = '@' `T.elem` getEmail email
  unless isValid $ throw InvalidEmail
  DB.addToWaitlist email
