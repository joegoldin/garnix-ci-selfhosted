module Garnix.Hosting.DeploySpec where

import Data.Map qualified as Map
import Garnix.Hosting.Deploy
import Garnix.Hosting.ServerPool.Types
import Garnix.Prelude
import Garnix.TestHelpers.Monad
import Test.Hspec

spec :: Spec
spec = inM $ do
  describe "_costBreakdown" $ do
    it "formats a cost breakdown of servers" $ do
      let servers =
            Map.fromList
              [ (I2x4, DeployCounts 0 1),
                (I4x8, DeployCounts 2 3),
                (I8x16, DeployCounts 2 0),
                (I16x32, DeployCounts 0 2)
              ]
      _costBreakdown servers
        `shouldBeM` [ "i2x4 (x1) = $15.00",
                      "i4x8 (x5) = $90.00 (2 included in plan, 3 not included at $30.00 each)",
                      "i8x16 (x2) = $0.00 (2 included in plan)",
                      "i16x32 (x2) = $240.00 ($120.00 each)"
                    ]

    it "omits lines with empty deploy counts" $ do
      let servers =
            Map.fromList
              [ (I2x4, DeployCounts 0 1),
                (I4x8, DeployCounts 0 0),
                (I8x16, DeployCounts 1 0),
                (I16x32, DeployCounts 0 0)
              ]
      _costBreakdown servers
        `shouldBeM` [ "i2x4 (x1) = $15.00",
                      "i8x16 (x1) = $0.00 (1 included in plan)"
                    ]
