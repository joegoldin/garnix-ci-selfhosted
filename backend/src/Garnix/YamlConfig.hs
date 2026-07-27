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
    BackupSchedule (..),
    BackupSection (..),
    parseBackupSchedule,
    validateBackupPaths,
    BuildSection (..),
    DeploySection (OnBranch, OnPullRequest),
    ExcludeBranches (..),
    GarnixConfig,
    IncrementalizeBuildsSection (..),
    ModuleSection (..),
    ServerSection (..),
    ServerApplicationLog (..),
    ServerLogFile (..),
    ServerPort (..),
    ServerPortType (..),
    exposeSSH,
    authorizeDeployerGithubKeys,
    authorizedSSHKeys,
    backups,
    ports,
    domains,
    logFile,
    paths,
    schedule,
    hours,
    raw,
    preBackupCommand,
    postBackupCommand,
    preRestoreCommand,
    postRestoreCommand,
    _garnixConfigActions,
    actions,
    asAttributeMatcher,
    authentikSection,
    autoCancelSuperseded,
    branchSection,
    buildSections,
    configuration,
    decodeConfig,
    decodeDeploySpec,
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
    thirdPart,
    fodChecks,
    flakeDir,
    safeGetAbsoluteFlakeDir,
  )
where

import Autodocodec
import Cradle qualified
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Text qualified as T
import Data.Tuple.Extra (fst3, snd3, thd3, uncurry3)
import Data.Void (Void)
import Data.Yaml (decodeEither', prettyPrintParseException)
import Data.Yaml qualified as Yaml
import GHC.IsList (fromList)
import Garnix.Duration (Duration)
import Garnix.Hosting.ServerPool.Types
import Garnix.Log
import Garnix.Monad
import Garnix.Monad.Async (timeoutThrowing)
import Garnix.NixConfig (addNixConfigEnvironment)
import Garnix.Prelude
import Garnix.Sandbox
-- Hide ServerToSpinUp's ssh field selectors: they collide with this module's
-- makeFields lenses of the same name (ServerSection), which we export instead.
-- YamlConfig doesn't use ServerToSpinUp.
import Garnix.Types hiding (authorizeDeployerGithubKeys, authorizedSSHKeys, domains, exposeSSH, logFile)
import System.Directory (doesFileExist)
import System.FilePath (isAbsolute, splitDirectories)
import Text.Read (readMaybe)

getConfigFromFlake :: (HasCallStack) => Duration -> M (Maybe GarnixConfig)
getConfigFromFlake evalTimeout = do
  cacheDir <- getNixXdgCacheDir
  nixConfig <- view #userNixConfig
  dir <- view #workingDir
  -- Configured eval timeout ('getConfiguredEvalTimeout'): a wedged nix-daemon
  -- (e.g. a deadlocked GC holding gc.lock) otherwise leaves this eval — and
  -- the whole push — stuck at "Build starting" forever.
  result <-
    timeoutThrowing evalTimeout (NixCommandTimeout {command = "nix eval .#garnix.config"})
      $ (>>= Cradle.run)
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
      -- Decode to a raw 'Aeson.Value' first (rather than straight to
      -- 'GarnixConfig') so a `servers:` key can be rejected LOUDLY —
      -- otherwise it would just silently fail 'decodeConfigValue' below and
      -- fall through to "Nothing", exactly like any other malformed
      -- `garnix.config` output. A repo's flake declaring
      -- `garnix.config.servers` is a migration mistake (the field moved
      -- into nixosConfigurations, same as the yaml `servers:` key — see
      -- 'rejectServersKey'), not "no config here", so it must throw.
      case decodeEither' stdout :: Either Yaml.ParseException Aeson.Value of
        Left _ -> pure Nothing
        Right value -> case rejectServersKey value of
          Left err -> throw $ DecodeConfigError (cs err)
          Right () -> case decodeConfigValue value of
            Left _ -> pure Nothing
            Right config -> pure $ Just config

getConfig :: (HasCallStack) => Duration -> M GarnixConfig
getConfig evalTimeout = do
  getConfigFromFlake evalTimeout >>= \case
    Just config -> pure config
    Nothing -> do
      dir <- view #workingDir
      exists' <- liftIO . doesFileExist $ dir </> "garnix.yaml"
      if exists'
        then do
          bytes <- liftIO . BS.readFile $ dir </> "garnix.yaml"
          case decodeConfig bytes of
            Left e -> throw $ DecodeConfigError (cs e)
            Right decoded -> pure decoded
        else pure def

-- | A `servers:` key anywhere at the top level (yaml file OR a flake's
-- `garnix.config` output) is a hard migration error: the section moved into
-- each nixosConfiguration's own `garnix.server` (see
-- docs/plans/2026-07-27-nix-native-server-config-design.md §3). Checked
-- against the raw parsed value BEFORE the codec gets a chance to just
-- quietly ignore the unrecognized key (autodocodec's default behavior for
-- unknown object keys).
rejectServersKey :: Aeson.Value -> Either String ()
rejectServersKey (Aeson.Object o)
  | KeyMap.member "servers" o =
      Left "servers: moved into nixosConfigurations — declare garnix.server in the configuration (see docs)"
rejectServersKey _ = Right ()

decodeConfigValue :: Aeson.Value -> Either String GarnixConfig
decodeConfigValue value = do
  rejectServersKey value
  parseEither parseJSONViaCodec value

decodeConfig :: ByteString -> Either String GarnixConfig
decodeConfig bytes = do
  value <- first prettyPrintParseException (decodeEither' bytes :: Either Yaml.ParseException Aeson.Value)
  decodeConfigValue value

-- | autodocodec's `optionalField` decodes "key ABSENT ⇒ Nothing"; it does
-- NOT accept an explicit JSON @null@ for that key (a decode error instead
-- — it tries to decode @null@ as the field's underlying type). Strip
-- null-valued keys from an object before handing it to a codec that uses
-- `optionalField`, so an explicit @null@ (as guest-profile.nix renders
-- every unset `nullOr` hook option) behaves the same as an absent key.
stripNulls :: Aeson.Value -> Aeson.Value
stripNulls (Aeson.Object o) = Aeson.Object (KeyMap.filter (/= Aeson.Null) o)
stripNulls v = v

-- | Decode a nix-declared @garnix.server.deploySpec@ JSON aggregate (see
-- provisioner/guest-profile.nix) into the SAME 'ServerSection' the yaml
-- codec used to produce for a repo's old `servers:` list — everything
-- downstream (deploy planning, domains validation, backups capture,
-- exposeSSH, persistence) stays unchanged. `configuration` isn't part of
-- the aggregate (it's implicit: whichever nixosConfiguration was
-- evaluated), so the caller supplies it. Returns 'Right Nothing' when
-- `deployment` is null (a buildable config that isn't a server — the
-- common case); 'Left' only for a malformed aggregate, which should not
-- happen for a value that satisfied guest-profile.nix's own assertions.
decodeDeploySpec :: PackageName -> Aeson.Value -> Either String (Maybe ServerSection)
decodeDeploySpec pkg = parseEither $ Aeson.withObject "deploySpec" $ \o -> do
  deploymentValue <- o Aeson..: "deployment"
  case deploymentValue of
    Aeson.Null -> pure Nothing
    _ -> do
      deploySection' <- parseJSONViaCodec deploymentValue
      domains' <- o Aeson..: "domains"
      exposeSSH' <- o Aeson..: "exposeSSH"
      authorizeDeployerGithubKeys' <- o Aeson..: "authorizeDeployerGithubKeys"
      authorizedSSHKeys' <- o Aeson..: "authorizedSSHKeys"
      portsValue <- o Aeson..: "ports"
      ports' <- parseJSONViaCodec portsValue
      applicationLogValue <- o Aeson..: "applicationLog"
      logFile' <- case applicationLogValue of
        Aeson.Null -> pure Nothing
        _ -> resolveServerApplicationLog <$> parseJSONViaCodec applicationLogValue
      backupsValue <- o Aeson..: "backups"
      backups' <- case backupsValue of
        Aeson.Null -> pure Nothing
        -- 'BackupSection's codec decodes its four optional hook fields via
        -- autodocodec's `optionalField`, which means "key ABSENT ⇒
        -- Nothing" — it errors on an explicit JSON `null`. The guest
        -- module's `nullOr str` hook options always render as explicit
        -- `null` when unset (never omitted), so strip null-valued keys
        -- first to line the two shapes up.
        _ -> Just <$> parseJSONViaCodec (stripNulls backupsValue)
      authentikDefault' <- o Aeson..:? "authentikDefault" Aeson..!= False
      pure
        $ Just
          ServerSection
            { _serverSectionConfiguration = pkg,
              _serverSectionDeploySection = deploySection',
              _serverSectionAuthentikSection = if authentikDefault' then Just "default" else Nothing,
              _serverSectionExposeSSH = exposeSSH',
              _serverSectionAuthorizeDeployerGithubKeys = authorizeDeployerGithubKeys',
              _serverSectionAuthorizedSSHKeys = authorizedSSHKeys',
              _serverSectionPorts = ports',
              _serverSectionDomains = domains',
              _serverSectionLogFile = logFile',
              _serverSectionBackups = backups'
            }

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

newtype ServerLogFile = ServerLogFile {getServerLogFile :: Text}
  deriving stock (Eq, Show, Generic)

defaultServerLogFile :: ServerLogFile
defaultServerLogFile = ServerLogFile "/var/log/nginx/hello-access.log"

instance HasCodec ServerLogFile where
  codec = bimapCodec validateServerLogFile getServerLogFile textCodec
    where
      validateServerLogFile path
        | not (isAbsolute (cs path)) = Left "applicationLog.path must be an absolute path"
        | ".." `elem` splitDirectories (cs path) = Left "applicationLog.path must not contain '..' path components"
        | T.any (`elem` ['\NUL', '\n', '\r']) path = Left "applicationLog.path must not contain NUL or newline characters"
        | otherwise = Right (ServerLogFile path)

-- | How often a server is backed up. Keeps the raw text the user wrote (for
-- faithful re-encoding) plus the resolved interval in hours.
data BackupSchedule = BackupSchedule
  { _backupScheduleRaw :: Text,
    _backupScheduleHours :: Int
  }
  deriving stock (Eq, Show, Generic)

parseBackupSchedule :: Text -> Either String BackupSchedule
parseBackupSchedule raw = case raw of
  "hourly" -> Right $ BackupSchedule raw 1
  "daily" -> Right $ BackupSchedule raw 24
  "weekly" -> Right $ BackupSchedule raw (24 * 7)
  _ -> case T.stripSuffix "h" raw of
    Just n | Just hours <- readMaybe (cs n), hours >= 1 -> Right $ BackupSchedule raw hours
    _ -> Left $ "backups.schedule must be hourly|daily|weekly or \"<N>h\" (N >= 1), got: " <> cs raw

instance HasCodec BackupSchedule where
  codec = bimapCodec parseBackupSchedule _backupScheduleRaw textCodec

validateBackupPath :: Text -> Either String Text
validateBackupPath path
  | not (isAbsolute (cs path)) = Left $ "backups.paths entries must be absolute paths, got: " <> cs path
  | path == "/" = Left "backups.paths must not contain /"
  | "/nix/store" `T.isPrefixOf` path = Left "backups.paths must not contain /nix/store paths"
  | ".." `elem` splitDirectories (cs path) = Left "backups.paths must not contain '..' components"
  | T.any (`elem` ['\NUL', '\n', '\r', '\'']) path = Left "backups.paths must not contain NUL, newline, or single-quote characters"
  | otherwise = Right path

validateBackupPaths :: [Text] -> Either String [Text]
validateBackupPaths [] = Left "backups.paths must not be empty"
validateBackupPaths paths = traverse validateBackupPath paths

data BackupSection = BackupSection
  { _backupSectionPaths :: [Text],
    _backupSectionSchedule :: BackupSchedule,
    _backupSectionPreBackupCommand :: Maybe Text,
    _backupSectionPostBackupCommand :: Maybe Text,
    _backupSectionPreRestoreCommand :: Maybe Text,
    _backupSectionPostRestoreCommand :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving (Aeson.FromJSON, Aeson.ToJSON) via (Autodocodec BackupSection)

instance HasCodec BackupSection where
  codec =
    object "backups"
      $ BackupSection
      <$> requiredFieldWith
        "paths"
        (bimapCodec validateBackupPaths identity codec)
        "Absolute paths inside the server to back up. Must not be empty, /, or under /nix/store."
      .= _backupSectionPaths
      <*> optionalFieldWithDefault
        "schedule"
        (BackupSchedule "daily" 24)
        "How often to back up: hourly | daily (default) | weekly | \"<N>h\"."
      .= _backupSectionSchedule
      <*> optionalField
        "preBackupCommand"
        "Command run on the server (as root, via sh -c) before the backup tar is taken. A non-zero exit aborts the backup."
      .= _backupSectionPreBackupCommand
      <*> optionalField
        "postBackupCommand"
        "Command run on the server after the tar is taken (cleanup). Always attempted, even if the tar failed."
      .= _backupSectionPostBackupCommand
      <*> optionalField
        "preRestoreCommand"
        "Command run on the server before a restore untars (e.g. stop your service)."
      .= _backupSectionPreRestoreCommand
      <*> optionalField
        "postRestoreCommand"
        "Command run on the server after a restore untars (e.g. start your service). Always attempted, even if the untar failed."
      .= _backupSectionPostRestoreCommand

data ServerApplicationLog = ServerApplicationLog
  { _serverApplicationLogEnable :: Bool,
    _serverApplicationLogPath :: ServerLogFile
  }
  deriving stock (Eq, Show, Generic)

instance Default ServerApplicationLog where
  def = ServerApplicationLog False defaultServerLogFile

instance HasCodec ServerApplicationLog where
  codec =
    object "applicationLog"
      $ ServerApplicationLog
      <$> optionalFieldWithDefault
        "enable"
        False
        "Stream the configured application log in the Servers-page Logs modal."
      .= _serverApplicationLogEnable
      <*> optionalFieldWithDefault
        "path"
        defaultServerLogFile
        "Absolute guest path to follow when application logging is enabled."
      .= _serverApplicationLogPath

resolveServerApplicationLog :: ServerApplicationLog -> Maybe ServerLogFile
resolveServerApplicationLog ServerApplicationLog {..}
  | _serverApplicationLogEnable = Just _serverApplicationLogPath
  | otherwise = Nothing

encodeServerApplicationLog :: Maybe ServerLogFile -> ServerApplicationLog
encodeServerApplicationLog = \case
  Nothing -> def
  Just path -> ServerApplicationLog True path

data ServerSection = ServerSection
  { _serverSectionConfiguration :: PackageName,
    _serverSectionDeploySection :: DeploySection,
    _serverSectionAuthentikSection :: Maybe Text,
    _serverSectionExposeSSH :: Bool,
    _serverSectionAuthorizeDeployerGithubKeys :: Bool,
    _serverSectionAuthorizedSSHKeys :: [Text],
    _serverSectionPorts :: [ServerPort],
    _serverSectionDomains :: [Text],
    _serverSectionLogFile :: Maybe ServerLogFile,
    _serverSectionBackups :: Maybe BackupSection
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
      <*> optionalFieldWithDefaultWith
        "applicationLog"
        ( dimapCodec
            resolveServerApplicationLog
            encodeServerApplicationLog
            (codec :: JSONCodec ServerApplicationLog)
        )
        Nothing
        "Optional application-log stream. Disabled by default; enable it to follow the configured absolute guest path over Garnix's private deploy SSH channel with bounded in-memory scrollback."
      .= _serverSectionLogFile
      <*> optionalField
        "backups"
        "Scheduled backups of paths on this server: garnix SSHes in on the schedule, tars the paths, and stores the snapshot in the operator's backup bucket. See also preBackupCommand/preRestoreCommand hooks."
      .= _serverSectionBackups

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
    _garnixConfigActions :: [Action],
    _garnixConfigArtifacts :: [ArtifactSection],
    _garnixConfigModuleSection :: ModuleSection,
    _garnixConfigFodChecks :: Bool,
    -- | Repo-declared (garnix.yaml), top-level: whether a new push (to the
    -- same branch, or for a fork PR, the same fork) cancels this repo's
    -- older not-yet-finished builds AND runs (deploys/actions/etc.) instead
    -- of letting them race the new push. See
    -- 'Garnix.Build.Flake.supersededCancellationScope' for the decision
    -- logic. Previously this was an admin-only Configure-page toggle; it now
    -- lives here so the repo itself declares the behavior instead of the
    -- operator.
    _garnixConfigAutoCancelSuperseded :: Bool,
    _garnixConfigFlakeDir :: FlakeDir
  }
  deriving stock (Eq, Show, Generic)

instance Default GarnixConfig where
  def = GarnixConfig [def] def [] [] def False False (FlakeDir ".")

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
                  "autoCancelSuperseded"
                  False
                  ( "Whether a new push (to the same branch, or for a fork "
                      <> "PR, the same fork) cancels this repo's older "
                      <> "not-yet-finished builds and runs (deploys/actions/"
                      <> "etc.) instead of letting them race the new push."
                  )
                  .= _garnixConfigAutoCancelSuperseded
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
makeFields ''BackupSection
makeFields ''BackupSchedule
makeFields ''Action
makeFields ''ArtifactSection
