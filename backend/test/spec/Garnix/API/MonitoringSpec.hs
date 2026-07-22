module Garnix.API.MonitoringSpec (spec) where

import Data.Map.Strict qualified as Map
import Garnix.API.Monitoring
import Garnix.Monad
import Garnix.Prelude
import Garnix.TestHelpers.Monad
import Test.Hspec

spec :: Spec
spec = inM $ describe "builder monitoring" $ do
  it "keeps configured order and isolates an unavailable builder" $ do
    let erdtree = MonitoringBuilderTarget "erdtree" "local" ["x86_64-linux"] 8
        farumAzula = MonitoringBuilderTarget "farum-azula" "remote" ["aarch64-linux"] 1
        scrapeTarget url
          | url == "local" =
              pure
                $ Map.fromList
                  [ ("node_load1", 1.5),
                    ("node_memory_MemTotal_bytes", 100),
                    ("node_memory_MemAvailable_bytes", 40),
                    ("node_cpu_seconds_total{cpu=\"0\",mode=\"idle\"}", 10)
                  ]
          | otherwise = pure Map.empty

    builders <- __collectBuilderStats scrapeTarget [erdtree, farumAzula]

    map _builderStatsName builders `shouldBeM` ["erdtree", "farum-azula"]
    map _builderStatsSystems builders `shouldBeM` [["x86_64-linux"], ["aarch64-linux"]]
    map _builderStatsMaxJobs builders `shouldBeM` [8, 1]
    map (_hostStatsScraped . _builderStatsStats) builders `shouldBeM` [True, False]
    map (_hostStatsLoad1 . _builderStatsStats) builders `shouldBeM` [Just 1.5, Nothing]
