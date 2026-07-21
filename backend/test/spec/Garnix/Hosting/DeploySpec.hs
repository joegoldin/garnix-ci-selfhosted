module Garnix.Hosting.DeploySpec where

import Garnix.Hosting.Deploy (statsEnvContents)
import Garnix.Prelude
import Garnix.Types (ProvisionedServerId (ProvisionedServerId))
import Test.Hspec

spec :: Spec
spec =
  describe "statsEnvContents" $ do
    it "preserves the configured full endpoint and provisioner id" $ do
      statsEnvContents "https://control.example/internal/stats" (ProvisionedServerId 42)
        `shouldBe` "GARNIX_STATS_URL=https://control.example/internal/stats\nGARNIX_PROVISIONER_ID=42\n"
