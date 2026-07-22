-- | Admin-only API for operator configuration that has no per-user home.
--
-- In self-host mode trusted builds use private inputs automatically and route
-- their outputs to the private cache. An external fork must first trigger the
-- restriction; only then does its base repo appear in the approval API below.
-- All endpoints are gated on the caller being an admin (subscription type
-- 'Admin', granted by the gateway's admin group in self-host mode).
module Garnix.API.Admin
  ( AdminAPI (..),
    adminAPI,
    PrivateInputForkRequestDto (..),
    SetPrivateInputForkApprovalDto (..),
    requireAdmin,
  )
where

import Control.Lens
import Garnix.DB qualified as DB
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import Servant (Put)
import Servant.Auth.Server

data AdminAPI route = AdminAPI
  { _adminAPIListPrivateInputForkRequests ::
      route
        :- "private-input-forks"
        :> Get '[JSON] [PrivateInputForkRequestDto],
    _adminAPISetPrivateInputForkApproval ::
      route
        :- "private-input-forks"
        :> Capture "owner" GhRepoOwner
        :> Capture "repo" GhRepoName
        :> ReqBody '[JSON] SetPrivateInputForkApprovalDto
        :> Put '[JSON] NoContent
  }
  deriving (Generic)

data PrivateInputForkRequestDto = PrivateInputForkRequestDto
  { _privateInputForkRequestDtoRepoUser :: GhRepoOwner,
    _privateInputForkRequestDtoRepoName :: GhRepoName,
    _privateInputForkRequestDtoAllowed :: Bool,
    _privateInputForkRequestDtoBlockedAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON PrivateInputForkRequestDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

newtype SetPrivateInputForkApprovalDto = SetPrivateInputForkApprovalDto
  { _setPrivateInputForkApprovalDtoAllowed :: Bool
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON SetPrivateInputForkApprovalDto where
  parseJSON = ourParseJSON

adminAPI :: AuthResult AuthJwtPayload -> AdminAPI (AsServerT M)
adminAPI auth =
  AdminAPI
    { _adminAPIListPrivateInputForkRequests = do
        requireAdmin auth
        fmap
          ( \(owner, repo, allowed, blockedAt) ->
              PrivateInputForkRequestDto
                { _privateInputForkRequestDtoRepoUser = owner,
                  _privateInputForkRequestDtoRepoName = repo,
                  _privateInputForkRequestDtoAllowed = allowed,
                  _privateInputForkRequestDtoBlockedAt = blockedAt
                }
          )
          <$> DB.getPrivateInputForkApprovalRequests,
      _adminAPISetPrivateInputForkApproval = \owner repo dto -> do
        requireAdmin auth
        DB.setPrivateInputForkApproval owner repo (_setPrivateInputForkApprovalDtoAllowed dto)
        pure NoContent
    }

-- | Throw 'Unauthorized' unless the request is from an authenticated admin.
requireAdmin :: AuthResult AuthJwtPayload -> M ()
requireAdmin (Authenticated ((^. #user) -> user)) =
  unless (user ^. subscriptionType == Admin) $ throw Unauthorized
requireAdmin _ = throw Unauthorized
