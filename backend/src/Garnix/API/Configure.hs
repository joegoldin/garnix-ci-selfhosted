-- | Self-host operator configuration exposed to the web UI's Configure page.
--
-- Currently: the global default build/eval timeout and per-repo overrides. All
-- endpoints are gated on self-host mode plus admin (the operator), matching the
-- admin API's auth. In cloud garnix these values come from billing plans, so
-- the endpoints refuse outside self-host mode.
module Garnix.API.Configure
  ( ConfigureAPI (..),
    configureAPI,
    ConfigureSettingsDto (..),
    RepoTimeoutDto (..),
    SetTimeoutDto (..),
  )
where

import Control.Lens
import Garnix.API.Admin (requireAdmin)
import Garnix.DB qualified as DB
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
          :> Delete '[JSON] NoContent
  }
  deriving (Generic)

-- | The current default timeout plus every per-repo override.
data ConfigureSettingsDto = ConfigureSettingsDto
  { _configureSettingsDtoDefaultBuildTimeoutMinutes :: Maybe Int32,
    _configureSettingsDtoRepoOverrides :: [RepoTimeoutDto]
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

configureAPI :: AuthResult AuthJwtPayload -> ConfigureAPI (AsServerT M)
configureAPI auth =
  ConfigureAPI
    { _configureAPIGet = do
        requireSelfHostConfig auth
        def <- DB.getDefaultBuildTimeout
        overrides <- DB.getReposWithBuildTimeout
        pure
          $ ConfigureSettingsDto
            { _configureSettingsDtoDefaultBuildTimeoutMinutes = def,
              _configureSettingsDtoRepoOverrides =
                map (\(o, r, m) -> RepoTimeoutDto o r m) overrides
            },
      _configureAPISetDefault = \dto -> do
        requireSelfHostConfig auth
        DB.setDefaultBuildTimeout (clamp <$> _setTimeoutDtoMinutes dto)
        pure NoContent,
      _configureAPISetRepo = \owner repo dto -> do
        requireSelfHostConfig auth
        case _setTimeoutDtoMinutes dto of
          Nothing -> throw $ OtherError "A timeout (in minutes) is required"
          Just m -> DB.setRepoBuildTimeout owner repo (Just (clamp m))
        pure NoContent,
      _configureAPIDeleteRepo = \owner repo -> do
        requireSelfHostConfig auth
        DB.setRepoBuildTimeout owner repo Nothing
        pure NoContent
    }
  where
    -- Keep values within the Int16 minute range the plan timeout fields use,
    -- with a 1-minute floor.
    clamp :: Int32 -> Int32
    clamp = min 32767 . max 1

-- | Throw 'Unauthorized' unless self-host mode is on and the caller is an admin.
requireSelfHostConfig :: AuthResult AuthJwtPayload -> M ()
requireSelfHostConfig auth = do
  selfHost <- view #selfHostMode
  unless selfHost $ throw Unauthorized
  requireAdmin auth
