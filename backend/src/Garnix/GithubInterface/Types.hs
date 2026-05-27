module Garnix.GithubInterface.Types (GhRole (..), GhUserOrgMembership (..)) where

import Data.Aeson (withObject, withText, (.:))
import Garnix.Prelude
import Garnix.Types hiding (Admin)

data GhRole = Admin | Other Text
  deriving stock (Show, Eq)

instance FromJSON GhRole where
  parseJSON = withText "GhRole" $ \role -> pure $ case role of
    "admin" -> Admin
    other -> Other other

data GhUserOrgMembership = GhUserOrgMembership
  { organizationName :: GhRepoOwner,
    role :: GhRole
  }
  deriving stock (Show, Eq)

instance FromJSON GhUserOrgMembership where
  parseJSON = withObject "GhUserOrgMembership" $ \v -> do
    org <- v .: "organization"
    name <- withObject "GhUserOrgMembership.organization" (.: "login") org
    role <- parseJSON =<< (v .: "role")
    pure $ GhUserOrgMembership name role
