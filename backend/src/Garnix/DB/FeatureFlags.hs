module Garnix.DB.FeatureFlags where

import Control.Concurrent.Lifted (modifyMVar)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Database.PostgreSQL.Typed (pgSQL)
import Garnix.DB qualified as DB
import Garnix.DB.FeatureFlags.Types
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import System.Random (randomRIO)

withRecachedFeatureFlags :: M a -> M a
withRecachedFeatureFlags action = do
  newConfig <- liftIO getFeatureFlagConfig
  local (#featureFlagConfig .~ newConfig) $ do
    action

isFeatureOn :: FeatureId -> M Bool
isFeatureOn id = do
  FeatureFlagConfigDbo config <- do
    FeatureFlagConfig mvar <- view #featureFlagConfig
    modifyMVar mvar $ \case
      Just config -> pure (Just config, config)
      Nothing -> do
        value :: [Aeson.Value] <-
          DB.pgQuery
            [pgSQL|
              SELECT config FROM feature_flags ORDER BY created_at DESC LIMIT 1;
            |]
        case value of
          [] -> pure def
          [json] -> case Aeson.parseEither parseJSON json of
            Right (config :: FeatureFlagConfigDbo) -> pure (Just config, config)
            Left e -> do
              log Critical $ "invalid json in feature_flags table: " <> cs e
              pure (Nothing, def)
          _ -> throw $ OtherError "impossible: more than two configs returned"
  case lookup id config of
    Nothing -> pure False
    Just config -> case config of
      Percentage percentage -> do
        random <- randomRIO (0, 99)
        pure $ random < percentage
      DisableFeature -> pure False

whenFeature :: FeatureId -> M () -> M ()
whenFeature id action = do
  enabled <- isFeatureOn id
  when enabled action
