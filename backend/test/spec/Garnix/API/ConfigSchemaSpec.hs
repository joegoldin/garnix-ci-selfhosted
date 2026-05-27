{-# LANGUAGE OverloadedRecordDot #-}

module Garnix.API.ConfigSchemaSpec where

import Autodocodec.Schema (JSONSchema)
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Yaml (decodeThrow)
import Garnix.Prelude
import Garnix.TestHelpers
import Garnix.TestHelpers.Monad
import Garnix.TestHelpers.WithServer
import Network.Wreq.Lens
import Test.Hspec
import Test.Hspec.Golden (defaultGolden)

spec :: Spec
spec = do
  describe "/api/garnix-config-schema.json" $ do
    inM $ aroundM_ suppressLogsWhenPassing $ do
      it "returns a json schema for the garnix yaml config" $ withServer $ \testServer -> do
        response <- assert200 $ testServer.get "/api/garnix-config-schema.json"
        _schema :: JSONSchema <- decodeThrow $ cs $ response ^. responseBody
        pure ()

    it "golden test for schema file" $ do
      runTestM $ suppressLogsWhenPassing $ withServer $ \testServer -> do
        response <- assertJSON $ assert200 $ testServer.get "/api/garnix-config-schema.json"
        pure $ defaultGolden "ConfigSchemaSpec/garnix-config-schema.json" $ cs $ encodePretty $ response ^. responseBody
