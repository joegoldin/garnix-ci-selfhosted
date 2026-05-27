{-# OPTIONS_GHC -Wno-orphans #-}

module Garnix.DB.FeatureFlagsSpec where

import Data.Aeson (encode)
import Data.Map qualified as Map
import Garnix.DB.FeatureFlags
import Garnix.DB.FeatureFlags.Types
import Garnix.Duration (fromSeconds)
import Garnix.Monad
import Garnix.Prelude
import Garnix.TestHelpers
import Garnix.TestHelpers.Monad
import Garnix.Types
import Test.Aeson.GenericSpecs
import Test.Hspec

spec :: Spec
spec = inM $ beforeM_ truncateDBM $ do
  describe "FeatureFlags" $ do
    ignoreSubject $ do
      it "converts the feature config into json" $ do
        encode (FeatureFlagConfigDbo (Map.toList (FodChecks ~> Percentage 42)))
          `shouldBe` encode [aesonQQ| [["FodChecks", {tag: "Percentage", contents: 42}]] |]

      roundtripSpecs (Proxy :: Proxy FeatureFlagConfigDbo)
      goldenSpecs (defaultSettings {goldenDirectoryOption = CustomDirectoryName ".golden"}) (Proxy :: Proxy FeatureFlagConfigDbo)

    it "considers features to be switched off by default" $ do
      isFeatureOn FodChecks `shouldReturnM` False

    it "allows to switch a feature on" $ do
      writeNewFeatureFlagsRaw [aesonQQ| [["FodChecks", {tag: "Percentage", contents: 100}]] |]
      isFeatureOn FodChecks `shouldReturnM` True

    it "allows re-reading the config (e.g. per request)" $ do
      isFeatureOn FodChecks `shouldReturnM` False
      writeNewFeatureFlagsRaw [aesonQQ| [["FodChecks", {tag: "Percentage", contents: 100}]] |]
      withRecachedFeatureFlags $ do
        isFeatureOn FodChecks `shouldReturnM` True

    it "allows to switch set a percentage for a feature" $ shouldTerminate (fromSeconds @Int 1) $ do
      let checkTrueAndFalse = do
            withRecachedFeatureFlags $ do
              let until expected = do
                    result <- isFeatureOn FodChecks
                    when (result /= expected) $ do
                      until expected
              until True
              until False
      writeNewFeatureFlagsRaw [aesonQQ| [["FodChecks", {tag: "Percentage", contents: 50}]] |]
      checkTrueAndFalse
      writeNewFeatureFlagsRaw [aesonQQ| [["FodChecks", {tag: "Percentage", contents: 1}]] |]
      checkTrueAndFalse
      writeNewFeatureFlagsRaw [aesonQQ| [["FodChecks", {tag: "Percentage", contents: 99}]] |]
      checkTrueAndFalse

    it "allows using percentages to fully switch features on or off" $ do
      let check expected = do
            withRecachedFeatureFlags $ do
              replicateM_ 1000 $ do
                isFeatureOn FodChecks `shouldReturnM` expected
      writeNewFeatureFlagsRaw [aesonQQ| [["FodChecks", {tag: "Percentage", contents: 100}]] |]
      check True
      writeNewFeatureFlagsRaw [aesonQQ| [["FodChecks", {tag: "Percentage", contents: 0}]] |]
      check False

    it "handles invalid json gracefully" $ suppressLogsWhenPassing $ do
      logs <- captureLogs_ $ do
        writeNewFeatureFlagsRaw [aesonQQ| "Invalid" |]
        withRecachedFeatureFlags $ do
          isFeatureOn FodChecks `shouldReturnM` False
      logs `shouldBeM` [LogItem Critical [] "invalid json in feature_flags table: Error in $: parsing [] failed, expected Array, but encountered String"]
