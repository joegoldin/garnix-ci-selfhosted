-- | Admin-only API for operator configuration that has no per-user home.
--
-- Currently exposes per-repo config: whether a public repo may depend on
-- private flake inputs, and whether its build outputs are routed to the
-- private (authenticated) cache bucket. Both are gated on the caller being an
-- admin (subscription type 'Admin', which in self-host mode is granted by the
-- gateway's admin group).
module Garnix.API.Admin
  ( AdminAPI (..),
    adminAPI,
    RepoConfigDto (..),
  )
where

import Control.Lens
import Garnix.DB qualified as DB
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import Servant.Auth.Server

data AdminAPI route = AdminAPI
  { _adminAPIGetRepoConfig ::
      route
        :- "repo-config"
          :> Capture "owner" GhRepoOwner
          :> Capture "repo" GhRepoName
          :> Get '[JSON] RepoConfigDto,
    _adminAPISetRepoConfig ::
      route
        :- "repo-config"
          :> Capture "owner" GhRepoOwner
          :> Capture "repo" GhRepoName
          :> ReqBody '[JSON] RepoConfigDto
          :> Post '[JSON] NoContent
  }
  deriving (Generic)

-- | The admin-configurable subset of a repo's config.
data RepoConfigDto = RepoConfigDto
  { _repoConfigDtoSkipPrivateInputsCheck :: Bool,
    _repoConfigDtoPrivateCache :: Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON RepoConfigDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

instance FromJSON RepoConfigDto where
  parseJSON = ourParseJSON

adminAPI :: AuthResult AuthJwtPayload -> AdminAPI (AsServerT M)
adminAPI auth =
  AdminAPI
    { _adminAPIGetRepoConfig = \owner repo -> do
        requireAdmin auth
        cfg <- DB.getRepoConfig owner repo
        pure
          $ RepoConfigDto
            { _repoConfigDtoSkipPrivateInputsCheck = cfg ^. skipPrivateInputsCheckForCollaborators,
              _repoConfigDtoPrivateCache = cfg ^. privateCache
            },
      _adminAPISetRepoConfig = \owner repo dto -> do
        requireAdmin auth
        DB.upsertRepoConfig
          owner
          repo
          (_repoConfigDtoSkipPrivateInputsCheck dto)
          (_repoConfigDtoPrivateCache dto)
        pure NoContent
    }

-- | Throw 'Unauthorized' unless the request is from an authenticated admin.
requireAdmin :: AuthResult AuthJwtPayload -> M ()
requireAdmin (Authenticated ((^. #user) -> user)) =
  unless (user ^. subscriptionType == Admin) $ throw Unauthorized
requireAdmin _ = throw Unauthorized
