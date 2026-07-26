module Garnix.Hosting.DeploySpec where

import Data.Text qualified as T
import Garnix.Hosting.Deploy (failedUnitsFromActivation, parseLoginUsers, statsEnvContents)
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

  describe "failedUnitsFromActivation" $ do
    it "extracts the units switch-to-configuration reports as failed" $ do
      failedUnitsFromActivation
        "activating the configuration...\nwarning: the following units failed: oauth2-proxy.service\n"
        `shouldBe` ["oauth2-proxy.service"]

    it "splits a comma-separated list and ignores surrounding output" $ do
      failedUnitsFromActivation
        "stopping the following units: a.service\nwarning: the following units failed: oauth2-proxy.service, nginx.service\nrestarting systemd...\n"
        `shouldBe` ["oauth2-proxy.service", "nginx.service"]

    it "returns nothing when no units failed" $ do
      failedUnitsFromActivation "activating the configuration...\nrestarting systemd...\n"
        `shouldBe` []

    -- The "NOT restarting the following changed units:" line is a normal part of
    -- every activation and must not be mistaken for a failure report.
    it "ignores the not-restarting notice" $ do
      failedUnitsFromActivation
        "NOT restarting the following changed units: getty@tty1.service, systemd-logind.service\n"
        `shouldBe` []

    it "deduplicates and caps pathological input" $ do
      let many' = T.intercalate ", " [cs (show @Int n) <> ".service" | n <- [1 .. 60]]
      length (failedUnitsFromActivation ("warning: the following units failed: " <> many'))
        `shouldBe` 25
      failedUnitsFromActivation
        "warning: the following units failed: a.service, a.service, b.service"
        `shouldBe` ["a.service", "b.service"]
