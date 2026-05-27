module Garnix.AccessToken.Types
  ( AccessToken (..),
    AccessTokenMetadata (..),
    AccessTokenScopes (..),
  )
where

import Control.Lens
import Data.Aeson qualified as Aeson
import Garnix.Prelude

newtype AccessToken = AccessToken {getAccessTokenText :: Text}
  deriving stock (Eq, Show, Generic, Ord)

instance ToJSON AccessToken where
  toJSON x = Aeson.String $ getAccessTokenText x

data AccessTokenMetadata = AccessTokenMetadata
  { _accessTokenMetadataId :: Int64,
    _accessTokenMetadataName :: Text,
    _accessTokenMetadataCreated :: UTCTime,
    _accessTokenMetadataLastUsed :: Maybe UTCTime,
    _accessTokenMetadataScopes :: AccessTokenScopes
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON AccessTokenMetadata where
  toJSON = ourToJSON

data AccessTokenScopes = AccessTokenScopes
  { cache :: Bool,
    api :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON AccessTokenScopes where
  parseJSON = Aeson.withObject "AccessTokenScopes" $ \o -> do
    cache <-
      o Aeson..:? "cache"
        <&> fromMaybe False
    api <-
      o Aeson..:? "api"
        <&> fromMaybe False
    pure $ AccessTokenScopes {cache, api}
