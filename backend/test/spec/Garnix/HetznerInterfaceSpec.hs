module Garnix.HetznerInterfaceSpec (spec) where

import Data.ByteString.Lazy qualified as BSL
import Garnix.HetznerInterface
import Garnix.Prelude
import Garnix.Types
import Test.Hspec

spec :: Spec
spec = do
  describe "_parseCreateServerResponse" $ do
    it "parses a sample Hetzner response" $ do
      createServerResponse <- BSL.readFile "test/spec/data/create-server-response.json"
      now <- liftIO getCurrentTime
      let expected =
            PreprovisionedServer
              { _preprovisionedServerId = PreprovisionedServerId 1,
                _preprovisionedServerHetznerServerId = HetznerServerId 26934828,
                _preprovisionedServerIpv4Addr = "167.235.59.80",
                _preprovisionedServerIpv6Addr = "2a01:4f8:c2c:8ee6::/64",
                _preprovisionedServerCreatedAt = now,
                _preprovisionedServerReadyAt = Nothing
              }
      _parseCreateServerResponse now createServerResponse `shouldBe` Just expected
