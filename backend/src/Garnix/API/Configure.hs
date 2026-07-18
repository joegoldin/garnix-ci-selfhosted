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
    RepoTimeoutDto (..),
    SetTimeoutDto (..),
    ArtifactRepoOverrideDto (..),
    ArtifactUsageDto (..),
    LockedArtifactBuildDto (..),
    SetArtifactDefaultsDto (..),
    SetArtifactRepoDto (..),
    ConnectedDomainDto (..),
    AddDomainDto (..),
    RepoRefDto (..),
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
    _configureSettingsDtoRepoOverrides :: [RepoTimeoutDto],
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

data RepoTimeoutDto = RepoTimeoutDto
  { _repoTimeoutDtoRepoUser :: GhRepoOwner,
    _repoTimeoutDtoRepoName :: GhRepoName,
    _repoTimeoutDtoBuildTimeoutMinutes :: Int32
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON RepoTimeoutDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

instance FromJSON RepoTimeoutDto where
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

-- | A registered connected domain (operator-owned base or single custom host)
-- and whether its DNS-points-here verification has passed.
data ConnectedDomainDto = ConnectedDomainDto
  { _connectedDomainDtoId :: Int64,
    _connectedDomainDtoDomain :: Text,
    _connectedDomainDtoIsWildcard :: Bool,
    _connectedDomainDtoVerified :: Bool
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
        overrides <- DB.getReposWithBuildTimeout
        (artifactRetentionDays, artifactKeepLatest) <- Artifacts.getArtifactSettings
        artifactOverrides <- Artifacts.getArtifactRepoOverrides
        artifactUsage <- Artifacts.getArtifactStorageUsage
        lockedBuilds <- Artifacts.getLockedArtifactBuilds
        pure
          $ ConfigureSettingsDto
            { _configureSettingsDtoDefaultBuildTimeoutMinutes = def,
              _configureSettingsDtoRepoOverrides =
                map (\(o, r, m) -> RepoTimeoutDto o r m) overrides,
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
        pure [ConnectedDomainDto cid d w (isJust v) | (cid, d, w, v) <- rows],
      _configureAPIAddDomain = \dto -> do
        requireSelfHostConfig auth
        let d = _addDomainDtoDomain dto
        cid <- DB.addConnectedDomain d True
        pure $ ConnectedDomainDto cid d True False,
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
            pure $ ConnectedDomainDto cid d w (ok || isJust v),
      _configureAPIDeleteDomain = \cid -> do
        requireSelfHostConfig auth
        DB.deleteConnectedDomain cid
        pure NoContent,
      _configureAPIListRepos = do
        requireSelfHostConfig auth
        map (\(o, r) -> RepoRefDto o r) <$> DB.getBuiltRepos
    }
  where
    -- Keep values within the Int16 minute range the plan timeout fields use.
    -- 0 is allowed and means "no limit"; the 1-hour default applies only when
    -- the value is cleared (Nothing), not when it is explicitly 0.
    -- (Artifact retention days are only floored at 0: a negative retention
    -- would make the reaper delete rows the moment they are created.)
    clamp :: Int32 -> Int32
    clamp = min 32767 . max 0

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
