{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# OPTIONS_GHC -Wno-partial-type-signatures #-}

module Garnix.API.HealthSpec (spec) where

import Garnix.Prelude
import Garnix.TestHelpers.Monad
import Garnix.TestHelpers.WithServer
import Test.Hspec

spec :: Spec
spec = do
  describe "/health/check" $ do
    inM $ it "returns 200 when everything is fine" $ withServer $ \testServer -> do
      void $ assert200 $ testServer.get "/api/health/check"
