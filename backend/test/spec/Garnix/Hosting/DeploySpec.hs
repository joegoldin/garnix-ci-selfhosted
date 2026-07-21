module Garnix.Hosting.DeploySpec where

import Garnix.Hosting.Deploy (statsEnvContents)
import Garnix.Prelude
import Garnix.Types (ProvisionedServerId (ProvisionedServerId))
import Test.Hspec

spec :: Spec
spec =
  describe "statsEnvContents" $ do
    it "renders the public endpoint and provisioner id for durable guest delivery" $ do
      statsEnvContents "garnix.example" (ProvisionedServerId 42)
        `shouldBe` "GARNIX_STATS_URL=https://garnix.example/api/hosts/stats\nGARNIX_PROVISIONER_ID=42\n"
