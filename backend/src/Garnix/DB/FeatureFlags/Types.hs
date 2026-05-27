module Garnix.DB.FeatureFlags.Types
  ( FeatureFlagConfig (..),
    FeatureFlagConfigDbo (..),
    FeatureId (..),
    FeatureConfig (..),
    getFeatureFlagConfig,
  )
where

import Control.Concurrent (MVar, newMVar)
import Data.Aeson qualified as Aeson
import Data.OpenApi (ToSchema)
import Garnix.Prelude

newtype FeatureFlagConfig = FeatureFlagConfig (MVar (Maybe FeatureFlagConfigDbo))

newtype FeatureFlagConfigDbo = FeatureFlagConfigDbo [(FeatureId, FeatureConfig)]
  deriving stock (Generic, Show, Eq)
  deriving newtype (ToJSON, FromJSON)

instance Default FeatureFlagConfigDbo where
  def = FeatureFlagConfigDbo mempty

instance PGColumn "json" FeatureFlagConfigDbo where
  pgDecode _ =
    either (\message -> error $ "Cannot decode FeatureFlagConfig json value: " <> cs message) identity
      . Aeson.eitherDecode @FeatureFlagConfigDbo
      . cs

instance ToSchema FeatureFlagConfigDbo

data FeatureId
  = FodChecks
  | BwrapBuildSandbox
  deriving (Generic, Ord, Eq, Show)

instance ToJSON FeatureId

instance ToJSONKey FeatureId where
  toJSONKey = Aeson.genericToJSONKey Aeson.defaultJSONKeyOptions

instance FromJSON FeatureId

instance FromJSONKey FeatureId where
  fromJSONKey = Aeson.genericFromJSONKey Aeson.defaultJSONKeyOptions

instance ToSchema FeatureId

data FeatureConfig
  = Percentage Int
  | DisableFeature
  deriving (Generic, Show, Eq)

instance ToJSON FeatureConfig

instance FromJSON FeatureConfig

instance ToSchema FeatureConfig

getFeatureFlagConfig :: IO FeatureFlagConfig
getFeatureFlagConfig = do
  FeatureFlagConfig <$> newMVar Nothing
