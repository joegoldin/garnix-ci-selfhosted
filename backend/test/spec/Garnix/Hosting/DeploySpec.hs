module Garnix.Hosting.DeploySpec where

import Garnix.Hosting.Deploy (parseLoginUsers, statsEnvContents)
import Garnix.Prelude
import Garnix.Types (ProvisionedServerId (ProvisionedServerId))
import Test.Hspec

spec :: Spec
spec = do
  describe "statsEnvContents" $ do
    it "preserves the configured full endpoint and provisioner id" $ do
      statsEnvContents "https://control.example/internal/stats" (ProvisionedServerId 42)
        `shouldBe` "GARNIX_STATS_URL=https://control.example/internal/stats\nGARNIX_PROVISIONER_ID=42\n"

  describe "parseLoginUsers" $ do
    it "omits root while retaining the deploy and declared login users" $ do
      parseLoginUsers
        "root:x:0:0:root:/root:/bin/bash\ngarnix:x:1000:100::/home/garnix:/bin/bash\njoe:x:1001:100::/home/joe:/bin/bash\nnobody:x:65534:65534::/:/sbin/nologin\n"
        `shouldBe` ["garnix", "joe"]
