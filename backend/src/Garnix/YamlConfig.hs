{-# LANGUAGE TemplateHaskell #-}
-- HasCodec instances make more sense here
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Garnix.YamlConfig
  ( Action (..),
    ActionSandboxType (..),
    ActionTrigger (..),
    GithubTokenMode (..),
    githubTokenModeScope,
    sandboxType,
    trigger,
    withRepoContents,
    githubToken,
    ArtifactSection (..),
    artifactDisplayName,
    artifacts,
    AttributeMatcher (..),
    BuildSection (..),
    DeploySection (OnBranch, OnPullRequest),
    ExcludeBranches (..),
    GarnixConfig,
    IncrementalizeBuildsSection (..),
    ModuleSection (..),
    ServerSection (..),
    ServerPort (..),
    ServerPortType (..),
    exposeSSH,
    authorizeDeployerGithubKeys,
    authorizedSSHKeys,
    ports,
    domains,
    _garnixConfigActions,
    actions,
    asAttributeMatcher,
    authentikSection,
    branchSection,
    buildSections,
    cancelSupersededBuilds,
    configuration,
    decodeConfig,
    deploySection,
    deployTypeExplanation,
    excludeBranches,
    excludeSection,
    firstPart,
    getConfig,
    includeSection,
    incrementalizeBuildsSection,
    moduleSection,
    parseAttributeMatcher,
    secondPart,
    serverSection,
    thirdPart,
    fodChecks,
    flakeDir,
    safeGetAbsoluteFlakeDir,
  )
where

import Autodocodec
import Cradle qualified
import Data.ByteString (ByteString)
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Text qualified as T
import Data.Tuple.Extra (fst3, snd3, thd3, uncurry3)
import Data.Void (Void)
import Data.Yaml (decodeEither', decodeFileEither, prettyPrintParseException)
import GHC.IsList (fromList)
import Garnix.Hosting.ServerPool.Types
import Garnix.Log
import Garnix.Monad
import Garnix.NixConfig (addNixConfigEnvironment)
import Garnix.Prelude
import Garnix.Sandbox
-- Hide ServerToSpinUp's ssh field selectors: they collide with this module's
-- makeFields lenses of the same name (ServerSection), which we export instead.
-- YamlConfig doesn't use ServerToSpinUp.
import Garnix.Types hiding (authorizeDeployerGithubKeys, authorizedSSHKeys, exposeSSH)
import System.Directory (doesFileExist)

getConfigFromFlake :: (HasCallStack) => M (Maybe GarnixConfig)
getConfigFromFlake = do
  cacheDir <- getNixXdgCacheDir
  nixConfig <- view #userNixConfig
  dir <- view #workingDir
  result <-
    (>>= Cradle.run)
      $ Cradle.cmd "nix"
      & Cradle.addArgs @Text
        [ "eval",
          ".#garnix.config",
          "--json"
        ]
      & addNixConfigEnvironment nixConfig
      & Cradle.setWorkingDir dir
      & Cradle.silenceStderr
      & pure
      & inNixSandbox [] (Just cacheDir)
  case result of
    (Cradle.ExitFailure _, _) -> pure Nothing
    (Cradle.ExitSuccess, Cradle.StdoutRaw stdout) ->
      case decodeEither' stdout of
        Left _ -> pure Nothing
        Right config -> pure $ Just config

getConfig :: (HasCallStack) => M GarnixConfig
getConfig = do
  getConfigFromFlake >>= \case
    Just config -> pure config
    Nothing -> do
      dir <- view #workingDir
      exists' <- liftIO . doesFileExist $ dir </> "garnix.yaml"
      if exists'
        then do
          eDecoded <- liftIO . decodeFileEither $ dir </> "garnix.yaml"
          case eDecoded of
            Left e -> throw $ DecodeConfigError . cs $ prettyPrintParseException e
            Right decoded -> pure decoded
        else pure def

decodeConfig :: ByteString -> Either String GarnixConfig
decodeConfig = first prettyPrintParseException . decodeEither'

newtype AttributePartMatcher = AttributePartMatcher {getAttributePartMatcher :: Text}
  deriving stock (Eq, Show, Generic)
  deriving newtype (IsString)

instance ConvertibleStrings Text AttributePartMatcher where
  convertString = AttributePartMatcher

instance ConvertibleStrings AttributePartMatcher Text where
  convertString = getAttributePartMatcher

-- E.g. 'packages.x86_64-linux.*' or 'nixosConfigurations.bar'
data AttributeMatcher = AttributeMatcher
  { _attributeMatcherFirstPart :: AttributePartMatcher,
    _attributeMatcherSecondPart :: AttributePartMatcher,
    _attributeMatcherThirdPart :: Maybe AttributePartMatcher
  }
  deriving stock (Eq, Show, Generic)

parseAttributeMatcher :: Text -> Either Text AttributeMatcher
parseAttributeMatcher x = case T.splitOn "." x of
  [a, b, c] -> pure $ AttributeMatcher (cs a) (cs b) (Just $ cs c)
  [a, b] -> pure $ AttributeMatcher (cs a) (cs b) Nothing
  _ -> Left "Expected 'x.y' or 'x.y.z'"

renderAttributeMatcher :: AttributeMatcher -> Text
renderAttributeMatcher a = case _attributeMatcherThirdPart a of
  Nothing -> cs (_attributeMatcherFirstPart a) <> "." <> cs (_attributeMatcherSecondPart a)
  Just t ->
    cs (_attributeMatcherFirstPart a)
      <> "."
      <> cs (_attributeMatcherSecondPart a)
      <> "."
      <> cs t

asAttributeMatcher :: Prism' Text AttributeMatcher
asAttributeMatcher = prism renderAttributeMatcher parseAttributeMatcher

instance HasCodec AttributeMatcher where
  codec = bimapCodec (first cs . parseAttributeMatcher) renderAttributeMatcher textCodec

data BuildSection = BuildSection
  { _buildSectionIncludeSection :: [AttributeMatcher],
    _buildSectionExcludeSection :: [AttributeMatcher],
    _buildSectionBranchSection :: Maybe Branch
  }
  deriving stock (Eq, Show, Generic)

defaultIncludeSection :: [AttributeMatcher]
defaultIncludeSection =
  [ AttributeMatcher "*" "x86_64-linux" (Just "*"),
    AttributeMatcher "defaultPackage" "x86_64-linux" Nothing,
    AttributeMatcher "devShell" "x86_64-linux" Nothing,
    AttributeMatcher "homeConfigurations" "*" Nothing,
    AttributeMatcher "darwinConfigurations" "*" Nothing,
    AttributeMatcher "nixosConfigurations" "*" Nothing
  ]

instance Default BuildSection where
  def = BuildSection defaultIncludeSection [] Nothing

attributeMatcherExplanation :: Text
attributeMatcherExplanation =
  "This is a list of *attribute matchers*, of the form `x.y.z` or `x.y`. "
    <> "For example, `packages.x86_64-linux.*`, or `*.*`. Two-place matchers only "
    <> "match two-place matchers, and three-place matchers only match three-place "
    <> "matchers. '*' is the wildcard."

instance HasCodec BuildSection where
  codec =
    object "builds"
      $ BuildSection
      <$> optionalFieldWithDefault
        "include"
        defaultIncludeSection
        ("What builds to include. " <> attributeMatcherExplanation)
      .= _buildSectionIncludeSection
      <*> optionalFieldWithDefault
        "exclude"
        []
        ( "What builds to exclude. "
            <> attributeMatcherExplanation
            <> " This is applied *after* the 'include'. Thus, if something matches"
            <> " both the 'include' and the 'exclude', it will be excluded."
        )
      .= _buildSectionExcludeSection
      <*> optionalField
        "branch"
        "What (optional) branch this build section is enabled for."
      .= _buildSectionBranchSection

data ExcludeBranches = ExcludeBranches {_excludeBranchesExcludeBranches :: [Branch]}
  deriving stock (Eq, Show, Generic)

instance HasCodec ExcludeBranches where
  codec =
    object "ExcludesBranches"
      $ ExcludeBranches
      <$> requiredField
        "excludeBranches"
        "What branches *not* to incrementalize"
      .= _excludeBranchesExcludeBranches

data IncrementalizeBuildsSection
  = IncrementalizeBuilds Bool
  | IncrementalBuildsExcludeBranches ExcludeBranches
  deriving stock (Eq, Show, Generic)

instance HasCodec IncrementalizeBuildsSection where
  codec = dimapCodec there back $ disjointEitherCodec simpleCodec codec
    where
      simpleCodec = boolCodec
      there = \case
        Left v -> IncrementalizeBuilds v
        Right v -> IncrementalBuildsExcludeBranches v
      back = \case
        IncrementalizeBuilds v -> Left v
        IncrementalBuildsExcludeBranches v -> Right v

instance Default IncrementalizeBuildsSection where
  def = IncrementalizeBuilds False

-- | An extra port to expose from a deployed server. @http@ ports become a
-- Traefik subdomain (@<name>.<server-domain>@); @tcp@ ports get a raw host-port
-- DNAT on the garnix host.
data ServerPort = ServerPort
  { _serverPortPort :: Int,
    _serverPortName :: Text,
    _serverPortType :: ServerPortType
  }
  deriving stock (Eq, Show, Generic)

data ServerPortType = HttpPort | TcpPort
  deriving stock (Eq, Show, Generic)

instance HasCodec ServerPortType where
  codec =
    stringConstCodec
      $ fromList [(HttpPort, "http"), (TcpPort, "tcp")]

instance HasCodec ServerPort where
  codec =
    object "serverPort"
      $ ServerPort
      <$> requiredField "port" "The port the service listens on inside the server."
      .= _serverPortPort
      <*> requiredField "name" "A short name; used as the subdomain (http) or label (tcp)."
      .= _serverPortName
      <*> optionalFieldWithDefault "type" HttpPort "\"http\" (default) exposes <name>.<server-domain>; \"tcp\" exposes a raw host:port."
      .= _serverPortType

data ServerSection = ServerSection
  { _serverSectionConfiguration :: PackageName,
    _serverSectionDeploySection :: DeploySection,
    _serverSectionAuthentikSection :: Maybe Text,
    _serverSectionExposeSSH :: Bool,
    _serverSectionAuthorizeDeployerGithubKeys :: Bool,
    _serverSectionAuthorizedSSHKeys :: [Text],
    _serverSectionPorts :: [ServerPort],
    _serverSectionDomains :: [Text]
  }
  deriving stock (Eq, Show, Generic)

instance HasCodec ServerSection where
  codec =
    object "servers"
      $ ServerSection
      <$> requiredField
        "configuration"
        "What attribute to deploy (e.g.: 'myServer' for 'nixosConfigurations.myServer')"
      .= _serverSectionConfiguration
      <*> requiredField
        "deployment"
        "When to deploy a new server, or redeploy an existing one"
      .= _serverSectionDeploySection
      <*> optionalField
        "authentik"
        "Set to \"default\" to have garnix drop its own OIDC (Authentik) credentials onto the deployed server at /var/garnix/keys/default-authentik.env, for use with the garnix-authentik guest module's mode = \"default\". The server is then gated by the exact same Authentik application (and entitlements) as garnix itself."
      .= _serverSectionAuthentikSection
      <*> optionalFieldWithDefault
        "exposeSSH"
        False
        "Open a public DNAT port on the garnix host forwarding to the guest's SSH (:22). Network reachability only; declare your login users in the guest config, or authorize the garnix user via authorizeDeployerGithubKeys/authorizedSSHKeys."
      .= _serverSectionExposeSSH
      <*> optionalFieldWithDefault
        "authorizeDeployerGithubKeys"
        False
        "Authorize the deployer's github.com/<user>.keys to log in as the garnix user on the deployed server."
      .= _serverSectionAuthorizeDeployerGithubKeys
      <*> optionalFieldWithDefault
        "authorizedSSHKeys"
        []
        "Extra SSH public keys to authorize for login as the garnix user on the deployed server."
      .= _serverSectionAuthorizedSSHKeys
      <*> optionalFieldWithDefault
        "ports"
        []
        "Extra ports to expose. http -> <name>.<server-domain>; tcp -> host:port."
      .= _serverSectionPorts
      <*> optionalFieldWithDefault
        "domains"
        []
        "Extra hostnames this server should also answer on (full FQDNs). A name under a configured base domain (the default apps domain or an operator/connected base) is wildcard-covered — no DNS action. Any other name is a bare custom domain and needs an A/CNAME record pointing at the garnix host (see the Servers page (i) menu). Each must be declared here (or in the Configure page) to be routed and get a cert."
      .= _serverSectionDomains

data DeploySection
  = OnPullRequest {tier :: ServerTier}
  | OnBranch
      { branch :: Branch,
        tier :: ServerTier,
        isPrimary :: Bool
      }
  deriving stock (Eq, Show, Generic)

deployTypeExplanation :: Text
deployTypeExplanation =
  "When and how to deploy. The current available types "
    <> "are: \n"
    <> " - on-branch: deploy a new version every time the HEAD of the specified "
    <> "branch changes."

instance HasCodec DeploySection where
  codec =
    object "deployment"
      $ discriminatedUnionCodec "type" serialize deserialize
    where
      branchCodec =
        (,,)
          <$> requiredField "branch" "What git branch to deploy from"
          .= fst3
          <*> optionalFieldWithDefault "machine" (def :: ServerTier) "What server tier to deploy"
          .= snd3
          <*> optionalFieldWithDefault "isPrimary" False "If this deploy should also be reachable at «repo-name».«org-name».garnix.me"
          .= thd3
      serialize :: DeploySection -> (Discriminator, ObjectCodec DeploySection ())
      serialize = \case
        OnBranch branch serverType isPrimary ->
          ( "on-branch",
            mapToEncoder (branch, serverType, isPrimary) branchCodec
          )
        OnPullRequest serverType -> ("on-pull-request", mapToEncoder serverType prCodec)
      prCodec =
        optionalFieldWithDefault "machine" (def :: ServerTier) "What server tier to deploy (i1x1|i2x2|...)."
      deserialize :: HashMap Discriminator (Text, ObjectCodec Void DeploySection)
      deserialize =
        HashMap.fromList
          [ ("on-branch", ("", mapToDecoder (uncurry3 OnBranch) branchCodec)),
            ("on-pull-request", ("", mapToDecoder OnPullRequest prCodec))
          ]

instance HasCodec Branch where
  codec = dimapCodec Branch getBranch textCodec

instance HasCodec ServerTier where
  codec =
    bimapCodec deserialize serialize textCodec
    where
      deserialize :: Text -> Either String ServerTier
      deserialize t =
        case lookup t (map swap serverTierTextMapping) of
          Just serverType -> Right serverType
          Nothing -> do
            let serverTypes = map snd serverTierTextMapping
            Left $ cs ("Wrong server type. Supported server types are: " <> T.intercalate ", " serverTypes)
      serialize :: ServerTier -> Text
      serialize serverType =
        case lookup serverType serverTierTextMapping of
          Just t -> t
          Nothing -> error "Unknown server type"

instance HasCodec PackageName where
  codec = dimapCodec PackageName getPackageName textCodec

data ActionSandboxType = FastStartup | SharedResources
  deriving (Eq, Show)

instance HasCodec ActionSandboxType where
  codec =
    stringConstCodec
      $ fromList
        [(FastStartup, "fast-startup"), (SharedResources, "shared-resources")]

-- | Currently only one value, so we don't even need to inspect it. But we
-- add it for documentation, and so we can remain backwards compatible
-- (otherwise, 'push' will always have to be the default).
data ActionTrigger = ActionTriggerPush
  deriving (Eq, Show)

instance HasCodec ActionTrigger where
  codec = stringConstCodec $ fromList [(ActionTriggerPush, "push")]

-- | Whether (and how) garnix mints a short-lived, scoped GitHub App
-- installation access token for an action, handing it to the action as both a
-- @GITHUB_TOKEN@ env var and nix @access-tokens = github.com=…@ (so
-- @github:@ flake-input fetches authenticate instead of hitting GitHub's
-- 60/hr anonymous rate limit). GitHub-only; a no-op on other forges.
--
-- Its garnix.yaml representation is a small union:
--
--   * a string — @none@ (default), @descoped@, @repo@ (this repo,
--     @contents: read@), or @repo-write@ (this repo, @contents: write@);
--   * a list of repo short-names — scope a @contents: read@ token to exactly
--     those repos (e.g. @githubToken: [nixpkgs, my-lib]@);
--   * an object — @{ repositories: [...], permission: read|write }@ for full
--     control (both fields optional; @repositories@ defaults to this repo,
--     @permission@ defaults to @read@).
data GithubTokenMode
  = -- | Default. Mint nothing; the action gets no GitHub token.
    GithubTokenNone
  | -- | Mint a token with no permissions (@permissions: {}@). Grants no repo
    -- access, but authenticates public-data fetches at 5000/hr instead of
    -- 60/hr. Enough for public @github:@ inputs (e.g. nixpkgs).
    GithubTokenDescoped
  | -- | Mint a token scoped to some repositories with a @contents@ read/write
    -- permission. The string @repo@ is sugar for
    -- @GithubTokenContents GithubTokenThisRepo GithubTokenRead@.
    GithubTokenContents GithubTokenRepositories GithubTokenPermission
  deriving stock (Eq, Show, Generic)

instance HasCodec GithubTokenPermission where
  codec =
    stringConstCodec
      $ fromList [(GithubTokenRead, "read"), (GithubTokenWrite, "write")]

instance HasCodec GithubTokenMode where
  codec =
    dimapCodec collapse expand
      $ disjointEitherCodec stringVariant
      $ disjointEitherCodec listVariant objectVariant
    where
      -- string: none | descoped | repo | repo-write
      stringVariant :: JSONCodec GithubTokenMode
      stringVariant =
        stringConstCodec
          $ fromList
            [ (GithubTokenNone, "none"),
              (GithubTokenDescoped, "descoped"),
              (GithubTokenContents GithubTokenThisRepo GithubTokenRead, "repo"),
              (GithubTokenContents GithubTokenThisRepo GithubTokenWrite, "repo-write")
            ]
      -- list of repo names -> contents:read scoped to those repos
      listVariant :: JSONCodec GithubTokenMode
      listVariant = dimapCodec fromRepoList toRepoList (codec :: JSONCodec [Text])
        where
          fromRepoList repos = GithubTokenContents (GithubTokenNamedRepos repos) GithubTokenRead
          toRepoList = \case
            GithubTokenContents (GithubTokenNamedRepos repos) _ -> repos
            _ -> []
      -- object: { repositories?: [...], permission?: read|write }
      objectVariant :: JSONCodec GithubTokenMode
      objectVariant = dimapCodec fromObj toObj $ object "githubToken" objCodec
        where
          objCodec =
            (,)
              <$> optionalFieldWithDefault
                "repositories"
                ([] :: [Text])
                "Repository short-names to scope the token to. Omit (or empty) for just this repo. All must belong to the same GitHub App installation."
              .= fst
              <*> optionalFieldWithDefault
                "permission"
                GithubTokenRead
                "The 'contents' permission granted: 'read' (default) or 'write'."
              .= snd
          fromObj (repos, perm) =
            GithubTokenContents
              (if null repos then GithubTokenThisRepo else GithubTokenNamedRepos repos)
              perm
          toObj = \case
            GithubTokenContents GithubTokenThisRepo perm -> ([], perm)
            GithubTokenContents (GithubTokenNamedRepos repos) perm -> (repos, perm)
            _ -> ([], GithubTokenRead)
      collapse :: Either GithubTokenMode (Either GithubTokenMode GithubTokenMode) -> GithubTokenMode
      collapse = \case
        Left m -> m
        Right (Left m) -> m
        Right (Right m) -> m
      expand :: GithubTokenMode -> Either GithubTokenMode (Either GithubTokenMode GithubTokenMode)
      expand = \case
        GithubTokenNone -> Left GithubTokenNone
        GithubTokenDescoped -> Left GithubTokenDescoped
        m@(GithubTokenContents GithubTokenThisRepo GithubTokenRead) -> Left m
        m@(GithubTokenContents GithubTokenThisRepo GithubTokenWrite) -> Left m
        m@(GithubTokenContents (GithubTokenNamedRepos _) GithubTokenRead) -> Right (Left m)
        m@(GithubTokenContents _ _) -> Right (Right m)

-- | The GitHub-facing token scope for a 'GithubTokenMode', or 'Nothing' when no
-- token should be minted ('GithubTokenNone').
githubTokenModeScope :: GithubTokenMode -> Maybe GithubTokenScope
githubTokenModeScope = \case
  GithubTokenNone -> Nothing
  GithubTokenDescoped -> Just GithubTokenScopeDescoped
  GithubTokenContents repos perm -> Just (GithubTokenScopeContents repos perm)

data Action = Action
  { _actionName :: PackageName,
    _actionTrigger :: ActionTrigger,
    _actionSandboxType :: ActionSandboxType,
    _actionWithRepoContents :: Bool,
    _actionGithubToken :: GithubTokenMode
  }
  deriving stock (Eq, Show, Generic)

instance HasCodec Action where
  codec =
    object "actions"
      $ Action
      <$> requiredField "run" "Name of the nix app to run as an action."
      .= _actionName
      <*> requiredField "on" "Event that triggers this action"
      .= _actionTrigger
      <*> optionalFieldWithDefault "sandboxType" FastStartup "What sandbox type. If you want to use the 'SharedResources' type, get in touch with us."
      .= _actionSandboxType
      <*> optionalFieldWithDefault "withRepoContents" False "Whether the action should run with access to the entire repo. If false (default), only the closure of the action is available."
      .= _actionWithRepoContents
      <*> optionalFieldWithDefault "githubToken" GithubTokenNone "Whether garnix mints a short-lived, scoped GitHub App token for this action, exposed as GITHUB_TOKEN and nix access-tokens so github: flake fetches authenticate (avoiding GitHub's 60/hr anonymous rate limit). GitHub-only. 'none' (default): no token. 'descoped': a token with no permissions that only lifts the anonymous rate limit (good for public inputs like nixpkgs). 'repo': a token scoped to this repo with contents:read, like GitHub Actions' GITHUB_TOKEN."
      .= _actionGithubToken

data ArtifactSection = ArtifactSection
  { _artifactSectionPackage :: PackageName,
    _artifactSectionName :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)

instance HasCodec ArtifactSection where
  codec =
    object "artifacts"
      $ ArtifactSection
      <$> requiredField
        "package"
        "The flake package whose build output is published as a downloadable artifact. Automatically included in builds."
      .= _artifactSectionPackage
      <*> optionalField
        "name"
        "The artifact's display/URL name ([a-zA-Z0-9._-]+). Defaults to the package name."
      .= _artifactSectionName

artifactDisplayName :: ArtifactSection -> Text
artifactDisplayName s = fromMaybe (getPackageName (_artifactSectionPackage s)) (_artifactSectionName s)

newtype ModuleSection = ModuleSection
  { publish :: Bool
  }
  deriving stock (Eq, Show, Generic)

instance HasCodec ModuleSection where
  codec = object "modules" $ do
    ModuleSection <$> optionalFieldWithDefault "publish" False "Whether to publish modules from this repository." .= publish

instance HasCodec FlakeDir where
  codec = dimapCodec FlakeDir __unsafeGetFlakeDir stringCodec

instance Default ModuleSection where
  def =
    ModuleSection
      { publish = False
      }

data GarnixConfig = GarnixConfig
  { _garnixConfigBuildSections :: [BuildSection],
    _garnixConfigIncrementalizeBuildsSection :: IncrementalizeBuildsSection,
    _garnixConfigServerSection :: [ServerSection],
    _garnixConfigActions :: [Action],
    _garnixConfigArtifacts :: [ArtifactSection],
    _garnixConfigModuleSection :: ModuleSection,
    _garnixConfigFodChecks :: Bool,
    _garnixConfigCancelSupersededBuilds :: Bool,
    _garnixConfigFlakeDir :: FlakeDir
  }
  deriving stock (Eq, Show, Generic)

instance Default GarnixConfig where
  def = GarnixConfig [def] def [] [] [] def False False (FlakeDir ".")

instance FromJSON GarnixConfig where
  parseJSON = parseJSONViaCodec

instance ToJSON GarnixConfig where
  toJSON = toJSONViaCodec

instance HasCodec GarnixConfig where
  codec = obj `parseAlternative` fmap (const def) nullCodec
    where
      obj :: JSONCodec GarnixConfig
      obj =
        object "config"
          $ GarnixConfig
          <$> ( optionalFieldWithDefaultWith
                  "builds"
                  ( dimapCodec
                      (either pure identity)
                      ( \case
                          [a] -> Left a
                          a -> Right a
                      )
                      $ disjointEitherCodec
                        (codec :: JSONCodec BuildSection)
                        (codec :: JSONCodec [BuildSection])
                  )
                  [def]
                  ( "Specifies what should be built. Everything in the `include` "
                      <> "section, minus everything in the `exclude` section, is built."
                  )
                  .= _garnixConfigBuildSections
              )
          <*> ( optionalFieldWithDefault
                  "incrementalizeBuilds"
                  def
                  ( "Whether to override the `garnix-incrementalize` flake input "
                      <> "to point to an parent built commit. This allows incremental "
                      <> "builds. See our https://garnix.io/docs for more information."
                  )
                  .= _garnixConfigIncrementalizeBuildsSection
              )
          <*> ( optionalFieldWithDefault
                  "servers"
                  []
                  "Specifies what servers to deploy."
                  .= _garnixConfigServerSection
              )
          <*> ( optionalFieldWithDefault
                  "actions"
                  []
                  "Specifies which actions to run."
                  .= _garnixConfigActions
              )
          <*> ( optionalFieldWithDefault
                  "artifacts"
                  []
                  "Build outputs to publish as downloadable artifacts."
                  .= _garnixConfigArtifacts
              )
          <*> ( optionalFieldWithDefault
                  "modules"
                  def
                  "Specifies which actions to run."
                  .= _garnixConfigModuleSection
              )
          <*> ( optionalFieldWithDefault
                  "fodChecks"
                  False
                  "Whether FOD checks are enabled for the repo. See https://garnix.io/docs/fod-checks for more information."
                  .= _garnixConfigFodChecks
              )
          <*> ( optionalFieldWithDefault
                  "cancelSupersededBuilds"
                  False
                  ( "Whether a new push to a branch cancels still-running and "
                      <> "queued builds of older commits on the same branch. "
                      <> "Useful when only the latest commit matters."
                  )
                  .= _garnixConfigCancelSupersededBuilds
              )
          <*> ( optionalFieldWithDefault
                  "flakeDir"
                  (FlakeDir ".")
                  "The directory containing your flake.nix relative from the repo root (if not in the repo root)."
                  .= _garnixConfigFlakeDir
              )

instance Loggable GarnixConfig where
  asLog = const []

makeFields ''ExcludeBranches
makeFields ''GarnixConfig
makeFields ''AttributeMatcher
makeFields ''BuildSection
makeFields ''ServerSection
makeFields ''Action
makeFields ''ArtifactSection
