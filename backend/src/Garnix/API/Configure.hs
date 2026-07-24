-- | Self-host operator configuration exposed to the web UI's Configure page.
--
-- Currently: the global default build/eval timeout and per-repo overrides,
-- plus artifact retention (global default + per-repo overrides), per-repo
-- artifact storage usage, and the locked-artifact-builds list. All endpoints
-- are gated on self-host mode plus admin (the operator), matching the admin
-- API's auth. In cloud garnix these values come from billing plans, so the
-- endpoints refuse outside self-host mode.
module Garnix.API.Configure
  ( ConfigureAPI (..),
    configureAPI,
    ConfigureSettingsDto (..),
    RepoRuntimeOverrideDto (..),
    SetTimeoutDto (..),
    SetEvaluationMemoryDto (..),
    SetDefaultAuthentikDto (..),
    SetFodCheckSkipDto (..),
    ArtifactRepoOverrideDto (..),
    ArtifactUsageDto (..),
    LockedArtifactBuildDto (..),
    SetArtifactDefaultsDto (..),
    SetArtifactRepoDto (..),
    ConnectedDomainDto (..),
    AddDomainDto (..),
    RepoRefDto (..),
    __verifyConfiguredDomain,
  )
where

import Control.Lens
import Garnix.API.Admin (requireAdmin)
import Garnix.DB qualified as DB
import Garnix.DB.Artifacts qualified as Artifacts
import Garnix.Dns (resolvesToHostingIp)
import Garnix.Entitlements (defaultBuildTimeoutMinutes)
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import Servant (Put)
import Servant.Auth.Server

data ConfigureAPI route = ConfigureAPI
  { _configureAPIGet ::
      route :- Get '[JSON] ConfigureSettingsDto,
    _configureAPISetDefault ::
      route
        :- "default"
        :> ReqBody '[JSON] SetTimeoutDto
        :> Put '[JSON] NoContent,
    _configureAPISetRepo ::
      route
        :- "repo"
        :> Capture "owner" GhRepoOwner
        :> Capture "repo" GhRepoName
        :> ReqBody '[JSON] SetTimeoutDto
        :> Put '[JSON] NoContent,
    _configureAPIDeleteRepo ::
      route
        :- "repo"
        :> Capture "owner" GhRepoOwner
        :> Capture "repo" GhRepoName
        :> Delete '[JSON] NoContent,
    _configureAPISetRepoEvaluationMemory ::
      route
        :- "repo"
        :> Capture "owner" GhRepoOwner
        :> Capture "repo" GhRepoName
        :> "evaluation-memory"
        :> ReqBody '[JSON] SetEvaluationMemoryDto
        :> Put '[JSON] NoContent,
    _configureAPIDeleteRepoEvaluationMemory ::
      route
        :- "repo"
        :> Capture "owner" GhRepoOwner
        :> Capture "repo" GhRepoName
        :> "evaluation-memory"
        :> Delete '[JSON] NoContent,
    _configureAPISetRepoDefaultAuthentik ::
      route
        :- "repo"
        :> Capture "owner" GhRepoOwner
        :> Capture "repo" GhRepoName
        :> "default-authentik"
        :> ReqBody '[JSON] SetDefaultAuthentikDto
        :> Put '[JSON] NoContent,
    _configureAPISetRepoFodCheckSkip ::
      route
        :- "repo"
        :> Capture "owner" GhRepoOwner
        :> Capture "repo" GhRepoName
        :> "fod-check-skip"
        :> ReqBody '[JSON] SetFodCheckSkipDto
        :> Put '[JSON] NoContent,
    _configureAPISetArtifactDefaults ::
      route
        :- "artifacts"
        :> "default"
        :> ReqBody '[JSON] SetArtifactDefaultsDto
        :> Put '[JSON] NoContent,
    _configureAPISetArtifactRepo ::
      route
        :- "artifacts"
        :> "repo"
        :> Capture "owner" GhRepoOwner
        :> Capture "repo" GhRepoName
        :> ReqBody '[JSON] SetArtifactRepoDto
        :> Put '[JSON] NoContent,
    _configureAPIDeleteArtifactRepo ::
      route
        :- "artifacts"
        :> "repo"
        :> Capture "owner" GhRepoOwner
        :> Capture "repo" GhRepoName
        :> Delete '[JSON] NoContent,
    _configureAPIListDomains ::
      route :- "domains" :> Get '[JSON] [ConnectedDomainDto],
    _configureAPIAddDomain ::
      route :- "domains" :> ReqBody '[JSON] AddDomainDto :> Post '[JSON] ConnectedDomainDto,
    _configureAPIVerifyConfiguredDomain ::
      route
        :- "domains"
        :> "configured"
        :> "verify"
        :> ReqBody '[JSON] AddDomainDto
        :> Post '[JSON] ConnectedDomainDto,
    _configureAPIVerifyDomain ::
      route :- "domains" :> Capture "id" Int64 :> "verify" :> Post '[JSON] ConnectedDomainDto,
    _configureAPIDeleteDomain ::
      route :- "domains" :> Capture "id" Int64 :> Delete '[JSON] NoContent,
    _configureAPIListRepos ::
      route :- "repos" :> Get '[JSON] [RepoRefDto]
  }
  deriving (Generic)

-- | The current default timeout plus every per-repo override, and the
-- artifact retention settings/usage/locks.
data ConfigureSettingsDto = ConfigureSettingsDto
  { _configureSettingsDtoDefaultBuildTimeoutMinutes :: Maybe Int32,
    _configureSettingsDtoDefaultMaxEvalMemoryGib :: Int64,
    _configureSettingsDtoRepoOverrides :: [RepoRuntimeOverrideDto],
    _configureSettingsDtoArtifactRetentionDays :: Int32,
    _configureSettingsDtoArtifactKeepLatest :: Bool,
    _configureSettingsDtoArtifactRepoOverrides :: [ArtifactRepoOverrideDto],
    _configureSettingsDtoArtifactUsage :: [ArtifactUsageDto],
    _configureSettingsDtoLockedArtifactBuilds :: [LockedArtifactBuildDto]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ConfigureSettingsDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

instance FromJSON ConfigureSettingsDto where
  parseJSON = ourParseJSON

data RepoRuntimeOverrideDto = RepoRuntimeOverrideDto
  { _repoRuntimeOverrideDtoRepoUser :: GhRepoOwner,
    _repoRuntimeOverrideDtoRepoName :: GhRepoName,
    _repoRuntimeOverrideDtoBuildTimeoutMinutes :: Maybe Int32,
    _repoRuntimeOverrideDtoMaxEvalMemoryGib :: Maybe Int64,
    -- | Whether this repo is admin-approved for @authentik: default@ hosting
    -- (sharing garnix's own OIDC client credentials with the deployed guest).
    _repoRuntimeOverrideDtoDefaultAuthentikApproved :: Bool,
    -- | Glob patterns (on a FOD's @\<name\>@) whose matching fixed-output
    -- derivations the FOD check skips instead of failing closed.
    _repoRuntimeOverrideDtoFodCheckSkip :: [Text]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON RepoRuntimeOverrideDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

instance FromJSON RepoRuntimeOverrideDto where
  parseJSON = ourParseJSON

-- | A timeout in minutes; 'Nothing' clears it (used for the global default).
newtype SetTimeoutDto = SetTimeoutDto
  { _setTimeoutDtoMinutes :: Maybe Int32
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SetTimeoutDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

instance FromJSON SetTimeoutDto where
  parseJSON = ourParseJSON

newtype SetEvaluationMemoryDto = SetEvaluationMemoryDto
  { _setEvaluationMemoryDtoGibibytes :: Int64
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SetEvaluationMemoryDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

instance FromJSON SetEvaluationMemoryDto where
  parseJSON = ourParseJSON

-- | Body of @PUT configure\/repo\/\<owner\>\/\<repo\>\/default-authentik@:
-- whether the repo is approved for @authentik: default@ hosting (which shares
-- garnix's own OIDC client credentials with the deployed guest).
newtype SetDefaultAuthentikDto = SetDefaultAuthentikDto
  { _setDefaultAuthentikDtoApproved :: Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SetDefaultAuthentikDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

instance FromJSON SetDefaultAuthentikDto where
  parseJSON = ourParseJSON

-- | Body of @PUT configure\/repo\/\<owner\>\/\<repo\>\/fod-check-skip@: the
-- full set of glob patterns (on a FOD's @\<name\>@) whose matching fixed-output
-- derivations the FOD check skips instead of failing closed. Replaces the
-- repo's existing list; an empty list clears it.
newtype SetFodCheckSkipDto = SetFodCheckSkipDto
  { _setFodCheckSkipDtoPatterns :: [Text]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SetFodCheckSkipDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

instance FromJSON SetFodCheckSkipDto where
  parseJSON = ourParseJSON

-- | A repo's artifact retention override. 'Nothing' fields inherit the
-- server-wide default.
data ArtifactRepoOverrideDto = ArtifactRepoOverrideDto
  { _artifactRepoOverrideDtoRepoUser :: GhRepoOwner,
    _artifactRepoOverrideDtoRepoName :: GhRepoName,
    _artifactRepoOverrideDtoRetentionDays :: Maybe Int32,
    _artifactRepoOverrideDtoKeepLatest :: Maybe Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ArtifactRepoOverrideDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

instance FromJSON ArtifactRepoOverrideDto where
  parseJSON = ourParseJSON

-- | A repo's artifact storage usage in bytes (dedupe-aware: shared
-- content-addressed objects count once per repo).
data ArtifactUsageDto = ArtifactUsageDto
  { _artifactUsageDtoRepoUser :: GhRepoOwner,
    _artifactUsageDtoRepoName :: GhRepoName,
    _artifactUsageDtoTotalSize :: Int64
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ArtifactUsageDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

instance FromJSON ArtifactUsageDto where
  parseJSON = ourParseJSON

-- | One locked artifact (per build + name): rows the reaper never deletes.
data LockedArtifactBuildDto = LockedArtifactBuildDto
  { _lockedArtifactBuildDtoBuildId :: BuildId,
    _lockedArtifactBuildDtoRepoUser :: GhRepoOwner,
    _lockedArtifactBuildDtoRepoName :: GhRepoName,
    _lockedArtifactBuildDtoBranch :: Maybe Branch,
    _lockedArtifactBuildDtoName :: Text,
    _lockedArtifactBuildDtoCreatedAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON LockedArtifactBuildDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

instance FromJSON LockedArtifactBuildDto where
  parseJSON = ourParseJSON

-- | Body of @PUT configure\/artifacts\/default@.
data SetArtifactDefaultsDto = SetArtifactDefaultsDto
  { _setArtifactDefaultsDtoRetentionDays :: Int32,
    _setArtifactDefaultsDtoKeepLatest :: Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SetArtifactDefaultsDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

instance FromJSON SetArtifactDefaultsDto where
  parseJSON = ourParseJSON

-- | Body of @PUT configure\/artifacts\/repo\/\<owner\>\/\<repo\>@. Absent and
-- null fields both mean "inherit the server default".
data SetArtifactRepoDto = SetArtifactRepoDto
  { _setArtifactRepoDtoRetentionDays :: Maybe Int32,
    _setArtifactRepoDtoKeepLatest :: Maybe Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SetArtifactRepoDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

instance FromJSON SetArtifactRepoDto where
  parseJSON = ourParseJSON

-- | A configured or registered hosting domain and whether its
-- DNS-points-here verification has passed. Configured rows have no database ID.
data ConnectedDomainDto = ConnectedDomainDto
  { _connectedDomainDtoId :: Maybe Int64,
    _connectedDomainDtoDomain :: Text,
    _connectedDomainDtoIsWildcard :: Bool,
    _connectedDomainDtoVerified :: Bool,
    _connectedDomainDtoNixConfigured :: Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ConnectedDomainDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

newtype AddDomainDto = AddDomainDto {_addDomainDtoDomain :: Text}
  deriving stock (Eq, Show, Generic)

instance FromJSON AddDomainDto where
  parseJSON = ourParseJSON

-- | A repo garnix has built for, for the Configure page's quick-links list.
data RepoRefDto = RepoRefDto
  { _repoRefDtoOwner :: GhRepoOwner,
    _repoRefDtoRepo :: GhRepoName
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON RepoRefDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

configureAPI :: AuthResult AuthJwtPayload -> ConfigureAPI (AsServerT M)
configureAPI auth =
  ConfigureAPI
    { _configureAPIGet = do
        requireSelfHostConfig auth
        def <- DB.getDefaultBuildTimeout
        overrides <- DB.getRepoRuntimeOverrides
        (artifactRetentionDays, artifactKeepLatest) <- Artifacts.getArtifactSettings
        artifactOverrides <- Artifacts.getArtifactRepoOverrides
        artifactUsage <- Artifacts.getArtifactStorageUsage
        lockedBuilds <- Artifacts.getLockedArtifactBuilds
        let minimumEvalMemory = defaultRepoConfig ^. maxEvalMemory
        pure
          $ ConfigureSettingsDto
            { _configureSettingsDtoDefaultBuildTimeoutMinutes = def,
              _configureSettingsDtoDefaultMaxEvalMemoryGib =
                toGigabytes minimumEvalMemory,
              _configureSettingsDtoRepoOverrides =
                map
                  ( \(o, r, timeout, memory, authentikApproved, fodCheckSkip) ->
                      RepoRuntimeOverrideDto
                        o
                        r
                        timeout
                        (toGigabytes . max minimumEvalMemory <$> memory)
                        authentikApproved
                        fodCheckSkip
                  )
                  overrides,
              _configureSettingsDtoArtifactRetentionDays = artifactRetentionDays,
              _configureSettingsDtoArtifactKeepLatest = artifactKeepLatest,
              _configureSettingsDtoArtifactRepoOverrides =
                map (\(o, r, d, k) -> ArtifactRepoOverrideDto o r d k) artifactOverrides,
              _configureSettingsDtoArtifactUsage =
                map (\(o, r, s) -> ArtifactUsageDto o r s) artifactUsage,
              _configureSettingsDtoLockedArtifactBuilds =
                map toLockedArtifactBuildDto lockedBuilds
            },
      _configureAPISetDefault = \dto -> do
        requireSelfHostConfig auth
        let mNew = clamp <$> _setTimeoutDtoMinutes dto
        DB.setDefaultBuildTimeout mNew
        -- Cancel builds already past the new effective cap (repos without an
        -- override). A cleared default (Nothing) means the 1h default now.
        DB.cancelRunningBuildsExceeding (fromMaybe defaultBuildTimeoutMinutes mNew) Nothing
        pure NoContent,
      _configureAPISetRepo = \owner repo dto -> do
        requireSelfHostConfig auth
        case _setTimeoutDtoMinutes dto of
          Nothing -> throw $ OtherError "A timeout (in minutes) is required"
          Just m -> do
            let c = clamp m
            DB.setRepoBuildTimeout owner repo (Just c)
            DB.cancelRunningBuildsExceeding c (Just (owner, repo))
        pure NoContent,
      _configureAPIDeleteRepo = \owner repo -> do
        requireSelfHostConfig auth
        DB.setRepoBuildTimeout owner repo Nothing
        -- Removing the override reverts this repo to the global default (or 1h).
        globalDefault <- DB.getDefaultBuildTimeout
        DB.cancelRunningBuildsExceeding (fromMaybe defaultBuildTimeoutMinutes globalDefault) (Just (owner, repo))
        pure NoContent,
      _configureAPISetRepoEvaluationMemory = \owner repo dto -> do
        requireSelfHostConfig auth
        let minimumGib = toGigabytes (defaultRepoConfig ^. maxEvalMemory)
            configuredGib = max minimumGib (_setEvaluationMemoryDtoGibibytes dto)
        DB.setRepoMaxEvalMemory owner repo (Just $ fromGigabytes configuredGib)
        pure NoContent,
      _configureAPIDeleteRepoEvaluationMemory = \owner repo -> do
        requireSelfHostConfig auth
        DB.setRepoMaxEvalMemory owner repo Nothing
        pure NoContent,
      _configureAPISetRepoDefaultAuthentik = \owner repo dto -> do
        requireSelfHostConfig auth
        DB.setDefaultAuthentikApproved owner repo (_setDefaultAuthentikDtoApproved dto)
        pure NoContent,
      _configureAPISetRepoFodCheckSkip = \owner repo dto -> do
        requireSelfHostConfig auth
        DB.setRepoFodCheckSkip owner repo (_setFodCheckSkipDtoPatterns dto)
        pure NoContent,
      _configureAPISetArtifactDefaults = \dto -> do
        requireSelfHostConfig auth
        Artifacts.setDefaultArtifactSettings
          (max 0 $ _setArtifactDefaultsDtoRetentionDays dto)
          (_setArtifactDefaultsDtoKeepLatest dto)
        pure NoContent,
      _configureAPISetArtifactRepo = \owner repo dto -> do
        requireSelfHostConfig auth
        Artifacts.setRepoArtifactSettings
          owner
          repo
          (max 0 <$> _setArtifactRepoDtoRetentionDays dto)
          (_setArtifactRepoDtoKeepLatest dto)
        pure NoContent,
      _configureAPIDeleteArtifactRepo = \owner repo -> do
        requireSelfHostConfig auth
        Artifacts.deleteRepoArtifactSettings owner repo
        pure NoContent,
      _configureAPIListDomains = do
        requireSelfHostConfig auth
        rows <- DB.getConnectedDomains
        configured <- configuredDomainNames
        configuredVerifications <- DB.getConfiguredDomainVerifications
        let configuredDtos =
              [ ConnectedDomainDto
                  Nothing
                  domain
                  True
                  (isJust $ lookup domain configuredVerifications)
                  True
                | domain <- configured
              ]
            registeredDtos =
              [ ConnectedDomainDto (Just cid) domain wildcard (isJust verifiedAt) False
                | (cid, domain, wildcard, verifiedAt) <- rows,
                  domain `notElem` configured
              ]
        pure $ configuredDtos <> registeredDtos,
      _configureAPIAddDomain = \dto -> do
        requireSelfHostConfig auth
        let d = _addDomainDtoDomain dto
        configured <- configuredDomainNames
        when (d `elem` configured) $ throw $ OtherError "Domain is already Nix-configured"
        cid <- DB.addConnectedDomain d True
        pure $ ConnectedDomainDto (Just cid) d True False False,
      _configureAPIVerifyConfiguredDomain = \dto -> do
        requireSelfHostConfig auth
        __verifyConfiguredDomain resolvesToHostingIp (_addDomainDtoDomain dto),
      _configureAPIVerifyDomain = \cid -> do
        requireSelfHostConfig auth
        rows <- DB.getConnectedDomains
        case find (\(i, _, _, _) -> i == cid) rows of
          Nothing -> throw $ OtherError "No such connected domain"
          Just (_, d, w, v) -> do
            -- A wildcard base can't have an A record on the apex label alone;
            -- probe a label under it. A single custom host is checked directly.
            let probe = if w then "garnix-verify." <> d else d
            ok <- resolvesToHostingIp probe
            when ok $ DB.markConnectedDomainVerified cid
            pure $ ConnectedDomainDto (Just cid) d w (ok || isJust v) False,
      _configureAPIDeleteDomain = \cid -> do
        requireSelfHostConfig auth
        DB.deleteConnectedDomain cid
        pure NoContent,
      _configureAPIListRepos = do
        requireSelfHostConfig auth
        map (uncurry RepoRefDto) <$> DB.getBuiltRepos
    }
  where
    -- Keep values within the Int16 minute range the plan timeout fields use.
    -- 0 is allowed and means "no limit"; the 1-hour default applies only when
    -- the value is cleared (Nothing), not when it is explicitly 0.
    -- (Artifact retention days are only floored at 0: a negative retention
    -- would make the reaper delete rows the moment they are created.)
    clamp :: Int32 -> Int32
    clamp = min 32767 . max 0

configuredDomainNames :: M [Text]
configuredDomainNames = do
  primary <- view #hostingDomain
  extras <- view #extraHostingDomains
  pure $ nub $ filter (/= "") (primary : extras)

__verifyConfiguredDomain :: (Text -> M Bool) -> Text -> M ConnectedDomainDto
__verifyConfiguredDomain resolver domain = do
  configured <- configuredDomainNames
  unless (domain `elem` configured) $ throw $ OtherError "Domain is not Nix-configured"
  prior <- lookup domain <$> DB.getConfiguredDomainVerifications
  ok <- resolver ("garnix-verify." <> domain)
  when ok $ DB.markConfiguredDomainVerified domain
  pure $ ConnectedDomainDto Nothing domain True (ok || isJust prior) True

toLockedArtifactBuildDto :: Artifacts.ArtifactRow -> LockedArtifactBuildDto
toLockedArtifactBuildDto row =
  LockedArtifactBuildDto
    { _lockedArtifactBuildDtoBuildId = Artifacts._artifactRowBuildId row,
      _lockedArtifactBuildDtoRepoUser = Artifacts._artifactRowRepoUser row,
      _lockedArtifactBuildDtoRepoName = Artifacts._artifactRowRepoName row,
      _lockedArtifactBuildDtoBranch = Artifacts._artifactRowBranch row,
      _lockedArtifactBuildDtoName = Artifacts._artifactRowName row,
      _lockedArtifactBuildDtoCreatedAt = Artifacts._artifactRowCreatedAt row
    }

-- | Throw 'Unauthorized' unless self-host mode is on and the caller is an admin.
requireSelfHostConfig :: AuthResult AuthJwtPayload -> M ()
requireSelfHostConfig auth = do
  selfHost <- view #selfHostMode
  unless selfHost $ throw Unauthorized
  requireAdmin auth
