module Garnix.Hosting.BillingSpec (spec) where

import Data.Map qualified as Map
import Garnix.Duration
import Garnix.Hosting.Helpers
  ( BranchServerBillingLineItem (..),
    BranchServerGroupIdentifier (BranchServerGroupIdentifier),
    calculateBranchDeploymentBillingLineItems,
    getBranchDeploymentBillingLineItems,
  )
import Garnix.Hosting.ServerPool.Types
import Garnix.Monad
import Garnix.MonetaryCost
import Garnix.Prelude
import Garnix.TestHelpers
import Garnix.TestHelpers.Monad
import Garnix.Types
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (forAll, suchThat)
import Test.QuickCheck.Arbitrary (Arbitrary (arbitrary))
import Test.QuickCheck.Gen (Gen)

spec :: Spec
spec = describe "billing line items" $ do
  describe "calculateBranchDeploymentBillingLineItems" $ do
    let testArbitrary :: Gen (Int64, UTCTime, UTCTime, [(BranchServerGroupIdentifier, Duration)])
        testArbitrary =
          arbitrary `suchThat` \(numFreeServers, periodStart, periodEnd, servers) ->
            (periodStart < periodEnd)
              && all ((> emptyDuration) . snd) servers
              && numFreeServers
              >= 0

    it "there is at most 1 extra line item (if a server is split)" $ forAll testArbitrary $ \(numFreeServers, periodStart, periodEnd, servers) -> do
      let result = calculateBranchDeploymentBillingLineItems numFreeServers periodStart periodEnd servers
      length result `shouldSatisfy` (<= (length servers + 1))

    prop "error in calculating line item durations is less than 1ms" $ forAll testArbitrary $ \(numFreeServers, periodStart, periodEnd, servers) -> do
      let result = calculateBranchDeploymentBillingLineItems numFreeServers periodStart periodEnd servers
      let totalServerDuration = foldr' (addDuration . snd) emptyDuration servers
      let totalResultDuration = foldr' (addDuration . (^. #usedTime)) emptyDuration result
      (totalServerDuration `subtractDuration` totalResultDuration) `shouldSatisfy` (<= fromMilliSeconds @Int 1)

    prop "the line items have the same groups as matched servers" $ forAll testArbitrary $ \(numFreeServers, periodStart, periodEnd, servers) -> do
      let result = calculateBranchDeploymentBillingLineItems numFreeServers periodStart periodEnd servers
      let serverSet = Map.keysSet $ Map.fromList servers
      let groupCount = Map.fromListWith (+) (map (\lineItem -> (lineItem ^. #group, 1 :: Int)) result)
      Map.keysSet groupCount `shouldBe` serverSet

    prop "at most 1 group is duplicated" $ forAll testArbitrary $ \(numFreeServers, periodStart, periodEnd, servers) -> do
      let result = calculateBranchDeploymentBillingLineItems numFreeServers periodStart periodEnd servers
      let groupCount = Map.fromListWith (+) (map (\lineItem -> (lineItem ^. #group, 1 :: Int)) result)
      length (Map.filter (> 2) groupCount) `shouldBe` 0
      length (Map.filter (== 2) groupCount) `shouldSatisfy` (<= 1)

  inM $ beforeM_ truncateDBM $ describe "getBranchDeploymentBillingLineItems" $ do
    let repoOwner = "test-user"
    let groupA = BranchServerGroupIdentifier repoOwner "repo-a" "server-a" I2x4
    let groupB = BranchServerGroupIdentifier repoOwner "repo-b" "server-b" I2x4
    let groupC = BranchServerGroupIdentifier repoOwner "repo-c" "server-c" I2x4
    let groupD = BranchServerGroupIdentifier repoOwner "repo-d" "server-d" I2x4

    let startOfMonth = parseTimestamp "2025-01-01T00:00:00Z"
    let endOfMonth = parseTimestamp "2025-02-01T00:00:00Z"
    let daysBeforeStart days = fromDays @Int days `subTime` startOfMonth
    let daysAfterEnd days = fromDays @Int days `addTime` endOfMonth
    let dayOfMonth day = fromDays @Int (day - 1) `addTime` startOfMonth

    let mkTestServers :: [(BranchServerGroupIdentifier, ServerInfo -> ServerInfo)] -> M ()
        mkTestServers serverConfigs = do
          forM_ serverConfigs $ \(group, serverConfig) -> do
            build <-
              testBuild
                $ (repoUser .~ group ^. #owner)
                . (repoName .~ group ^. #repo)
                . (package .~ group ^. #package)
            void
              $ addTestServer
              $ (configurationBuildId .~ build ^. id)
              . (tier .~ group ^. #serverTier)
              . serverConfig

    it "returns no line items if there are no servers deployed in the period" $ do
      mkTestServers
        [ (groupA, (readyAt ?~ daysBeforeStart 60) . (endedAt ?~ daysBeforeStart 30)),
          (groupB, (readyAt ?~ daysBeforeStart 30) . (endedAt ?~ startOfMonth)),
          (groupB, (readyAt ?~ endOfMonth) . (endedAt .~ Nothing)),
          (groupA, (readyAt ?~ daysAfterEnd 30) . (endedAt .~ Nothing))
        ]
      lineItems <- getBranchDeploymentBillingLineItems 1 startOfMonth endOfMonth repoOwner
      lineItems `shouldBeM` []

    it "returns a line item included in plan if the period only has a single free server" $ do
      mkTestServers
        [ (groupA, (readyAt ?~ daysBeforeStart 30) . (endedAt .~ Nothing))
        ]
      lineItems <- getBranchDeploymentBillingLineItems 1 startOfMonth endOfMonth repoOwner
      lineItems
        `shouldBeM` [ BranchServerBillingLineItem {group = groupA, includedInPlan = True, usedTime = fromDays @Int 31, cost = usd 0}
                    ]

    it "bills for one server-month if there are two servers for the duration of the month" $ do
      mkTestServers
        [ (groupA, (readyAt ?~ startOfMonth) . (endedAt .~ Nothing)),
          (groupB, (readyAt ?~ startOfMonth) . (endedAt .~ Nothing))
        ]
      lineItems <- getBranchDeploymentBillingLineItems 1 startOfMonth endOfMonth repoOwner
      lineItems
        `shouldBeM` [ BranchServerBillingLineItem {group = groupA, includedInPlan = True, usedTime = fromDays @Int 31, cost = usd 0},
                      BranchServerBillingLineItem {group = groupB, includedInPlan = False, usedTime = fromDays @Int 31, cost = usd 15}
                    ]

    it "bills correctly for shorter billing periods (i.e. shorter months)" $ do
      let shortMonthStart = parseTimestamp "2025-02-01T00:00:00Z"
      let shortMonthEnd = parseTimestamp "2025-03-01T00:00:00Z"
      mkTestServers
        [ (groupA, (readyAt ?~ shortMonthStart) . (endedAt .~ Nothing)),
          (groupB, (readyAt ?~ shortMonthStart) . (endedAt .~ Nothing))
        ]
      lineItems <- getBranchDeploymentBillingLineItems 1 shortMonthStart shortMonthEnd repoOwner
      lineItems
        `shouldBeM` [ BranchServerBillingLineItem {group = groupA, includedInPlan = True, usedTime = fromDays @Int 28, cost = usd 0},
                      BranchServerBillingLineItem {group = groupB, includedInPlan = False, usedTime = fromDays @Int 28, cost = usd 15}
                    ]

    it "handles partial month server usage" $ do
      mkTestServers
        [ -- Free server used for the entire month (included in plan)
          (groupA, (readyAt ?~ startOfMonth) . (endedAt .~ Nothing)),
          -- A server used for 8 days within the month
          (groupB, (readyAt ?~ dayOfMonth 2) . (endedAt ?~ dayOfMonth 10)),
          -- A server used for 4 days within the month
          (groupC, (readyAt ?~ dayOfMonth 28) . (endedAt ?~ daysAfterEnd 30)),
          -- A server used for 2 days within the month
          (groupD, (readyAt ?~ daysBeforeStart 30) . (endedAt ?~ dayOfMonth 3))
        ]
      lineItems <- getBranchDeploymentBillingLineItems 1 startOfMonth endOfMonth repoOwner
      lineItems
        `shouldBeM` [ BranchServerBillingLineItem {group = groupA, includedInPlan = True, usedTime = fromDays @Int 31, cost = usd 0},
                      BranchServerBillingLineItem {group = groupB, includedInPlan = False, usedTime = fromDays @Int 8, cost = roundFromUsd (15 * 8 / 31)},
                      BranchServerBillingLineItem {group = groupC, includedInPlan = False, usedTime = fromDays @Int 4, cost = roundFromUsd (15 * 4 / 31)},
                      BranchServerBillingLineItem {group = groupD, includedInPlan = False, usedTime = fromDays @Int 2, cost = roundFromUsd (15 * 2 / 31)}
                    ]

    it "utilizes the longest durations for the `included in plan` time first (and orders them first)" $ do
      mkTestServers
        [ (groupA, (readyAt ?~ dayOfMonth 16) . (endedAt .~ Nothing)),
          (groupB, (readyAt ?~ dayOfMonth 25) . (endedAt .~ Nothing)),
          (groupC, (readyAt ?~ dayOfMonth 26) . (endedAt .~ Nothing)),
          (groupD, (readyAt ?~ dayOfMonth 17) . (endedAt .~ Nothing))
        ]
      lineItems <- getBranchDeploymentBillingLineItems 1 startOfMonth endOfMonth repoOwner
      lineItems
        `shouldBeM` [ BranchServerBillingLineItem {group = groupA, includedInPlan = True, usedTime = fromDays @Int 16, cost = usd 0},
                      BranchServerBillingLineItem {group = groupD, includedInPlan = True, usedTime = fromDays @Int 15, cost = usd 0},
                      BranchServerBillingLineItem {group = groupB, includedInPlan = False, usedTime = fromDays @Int 7, cost = roundFromUsd (15 * 7 / 31)},
                      BranchServerBillingLineItem {group = groupC, includedInPlan = False, usedTime = fromDays @Int 6, cost = roundFromUsd (15 * 6 / 31)}
                    ]

    it "groups servers by owner+repo+package" $ do
      mkTestServers
        [ -- Multiple groupA deployments totaling to 21 days
          (groupA, (readyAt ?~ startOfMonth) . (endedAt ?~ dayOfMonth 6)),
          (groupA, (readyAt ?~ startOfMonth) . (endedAt ?~ dayOfMonth 7)),
          (groupA, (readyAt ?~ startOfMonth) . (endedAt ?~ dayOfMonth 8)),
          -- Multiple groupB deployments totaling 7 days
          (groupB, (readyAt ?~ startOfMonth) . (endedAt ?~ dayOfMonth 4)),
          (groupB, (readyAt ?~ startOfMonth) . (endedAt ?~ dayOfMonth 5)),
          -- One groupC deployment totaling 2 days
          (groupC, (readyAt ?~ startOfMonth) . (endedAt ?~ dayOfMonth 3))
        ]
      lineItems <- getBranchDeploymentBillingLineItems 1 startOfMonth endOfMonth repoOwner
      lineItems
        `shouldBeM` [ BranchServerBillingLineItem {group = groupA, includedInPlan = True, usedTime = fromDays @Int 18, cost = usd 0},
                      BranchServerBillingLineItem {group = groupB, includedInPlan = True, usedTime = fromDays @Int 7, cost = usd 0},
                      BranchServerBillingLineItem {group = groupC, includedInPlan = True, usedTime = fromDays @Int 2, cost = usd 0}
                    ]

    it "splits a single group into two line items if it is only partly covered by the plan time" $ do
      mkTestServers
        [ -- Single server that takes up 28 out of 31 days
          (groupA, (readyAt ?~ startOfMonth) . (endedAt ?~ dayOfMonth 29)),
          -- This server uses 5 days, 3 of which are included in the plan, but the rest are not
          (groupB, (readyAt ?~ startOfMonth) . (endedAt ?~ dayOfMonth 6))
        ]
      lineItems <- getBranchDeploymentBillingLineItems 1 startOfMonth endOfMonth repoOwner
      lineItems
        `shouldBeM` [ BranchServerBillingLineItem {group = groupA, includedInPlan = True, usedTime = fromDays @Int 28, cost = usd 0},
                      BranchServerBillingLineItem {group = groupB, includedInPlan = True, usedTime = fromDays @Int 3, cost = usd 0},
                      BranchServerBillingLineItem {group = groupB, includedInPlan = False, usedTime = fromDays @Int 2, cost = roundFromUsd (15 * 2 / 31)}
                    ]

    it "bills a server redeployed multiple times at the total cost per month" $ do
      mkTestServers
        [ (groupA, (readyAt ?~ startOfMonth) . (endedAt .~ Nothing)),
          (groupB, (readyAt ?~ startOfMonth) . (endedAt ?~ dayOfMonth 5)),
          (groupB, (readyAt ?~ dayOfMonth 5) . (endedAt ?~ dayOfMonth 6)),
          (groupB, (readyAt ?~ dayOfMonth 6) . (endedAt ?~ dayOfMonth 7)),
          (groupB, (readyAt ?~ dayOfMonth 7) . (endedAt ?~ dayOfMonth 8)),
          (groupB, (readyAt ?~ dayOfMonth 8) . (endedAt .~ Nothing))
        ]
      lineItems <- getBranchDeploymentBillingLineItems 1 startOfMonth endOfMonth repoOwner
      lineItems
        `shouldBeM` [ BranchServerBillingLineItem {group = groupA, includedInPlan = True, usedTime = fromDays @Int 31, cost = usd 0},
                      BranchServerBillingLineItem {group = groupB, includedInPlan = False, usedTime = fromDays @Int 31, cost = usd 15}
                    ]

    it "allows plans to specify more than one free server" $ do
      mkTestServers
        [ (groupA, (readyAt ?~ startOfMonth) . (endedAt .~ Nothing)),
          (groupB, (readyAt ?~ startOfMonth) . (endedAt .~ Nothing)),
          (groupC, (readyAt ?~ startOfMonth) . (endedAt .~ Nothing)),
          (groupD, (readyAt ?~ startOfMonth) . (endedAt .~ Nothing))
        ]
      lineItems <- getBranchDeploymentBillingLineItems 3 startOfMonth endOfMonth repoOwner
      lineItems
        `shouldBeM` [ BranchServerBillingLineItem {group = groupA, includedInPlan = True, usedTime = fromDays @Int 31, cost = usd 0},
                      BranchServerBillingLineItem {group = groupB, includedInPlan = True, usedTime = fromDays @Int 31, cost = usd 0},
                      BranchServerBillingLineItem {group = groupC, includedInPlan = True, usedTime = fromDays @Int 31, cost = usd 0},
                      BranchServerBillingLineItem {group = groupD, includedInPlan = False, usedTime = fromDays @Int 31, cost = usd 15}
                    ]

    describe "server tiers" $ do
      let tierI2x4 = groupA & (#serverTier .~ I2x4)
      let tierI4x8 = groupA & (#serverTier .~ I4x8)
      let tierI8x16 = groupA & (#serverTier .~ I8x16)
      let tierI16x32 = groupA & (#serverTier .~ I16x32)

      it "groups line items by server tier and bills them correctly including one free server" $ do
        mkTestServers
          [ (tierI2x4, (readyAt ?~ startOfMonth) . (endedAt .~ Nothing)),
            (tierI2x4, (readyAt ?~ startOfMonth) . (endedAt .~ Nothing)),
            (tierI4x8, (readyAt ?~ startOfMonth) . (endedAt .~ Nothing)),
            (tierI8x16, (readyAt ?~ startOfMonth) . (endedAt .~ Nothing)),
            (tierI16x32, (readyAt ?~ startOfMonth) . (endedAt .~ Nothing))
          ]
        lineItems <- getBranchDeploymentBillingLineItems 1 startOfMonth endOfMonth repoOwner
        lineItems
          `shouldBeM` [ BranchServerBillingLineItem {group = tierI2x4, includedInPlan = True, usedTime = fromDays @Int 31, cost = usd 0},
                        BranchServerBillingLineItem {group = tierI2x4, includedInPlan = False, usedTime = fromDays @Int 31, cost = usd 15},
                        BranchServerBillingLineItem {group = tierI4x8, includedInPlan = False, usedTime = fromDays @Int 31, cost = usd 30},
                        BranchServerBillingLineItem {group = tierI8x16, includedInPlan = False, usedTime = fromDays @Int 31, cost = usd 60},
                        BranchServerBillingLineItem {group = tierI16x32, includedInPlan = False, usedTime = fromDays @Int 31, cost = usd 120}
                      ]

      it "does not include a free server if no server groups are i2x4" $ do
        mkTestServers
          [ (tierI4x8, (readyAt ?~ startOfMonth) . (endedAt .~ Nothing)),
            (tierI8x16, (readyAt ?~ startOfMonth) . (endedAt .~ Nothing)),
            (tierI16x32, (readyAt ?~ startOfMonth) . (endedAt .~ Nothing))
          ]
        lineItems <- getBranchDeploymentBillingLineItems 1 startOfMonth endOfMonth repoOwner
        lineItems
          `shouldBeM` [ BranchServerBillingLineItem {group = tierI4x8, includedInPlan = False, usedTime = fromDays @Int 31, cost = usd 30},
                        BranchServerBillingLineItem {group = tierI8x16, includedInPlan = False, usedTime = fromDays @Int 31, cost = usd 60},
                        BranchServerBillingLineItem {group = tierI16x32, includedInPlan = False, usedTime = fromDays @Int 31, cost = usd 120}
                      ]

      it "correctly bills partial usage of higher-cost servers" $ do
        mkTestServers
          [ (tierI16x32, (readyAt ?~ startOfMonth) . (endedAt ?~ dayOfMonth 26)),
            (tierI8x16, (readyAt ?~ startOfMonth) . (endedAt ?~ dayOfMonth 21)),
            (tierI4x8, (readyAt ?~ startOfMonth) . (endedAt ?~ dayOfMonth 16))
          ]
        lineItems <- getBranchDeploymentBillingLineItems 1 startOfMonth endOfMonth repoOwner
        lineItems
          `shouldBeM` [ BranchServerBillingLineItem {group = tierI16x32, includedInPlan = False, usedTime = fromDays @Int 25, cost = roundFromUsd (120 * 25 / 31)},
                        BranchServerBillingLineItem {group = tierI8x16, includedInPlan = False, usedTime = fromDays @Int 20, cost = roundFromUsd (60 * 20 / 31)},
                        BranchServerBillingLineItem {group = tierI4x8, includedInPlan = False, usedTime = fromDays @Int 15, cost = roundFromUsd (30 * 15 / 31)}
                      ]

      it "does not count ineligible time used when calculating free servers" $ do
        mkTestServers
          [ (tierI16x32, (readyAt ?~ startOfMonth) . (endedAt .~ Nothing)),
            (tierI2x4, (readyAt ?~ startOfMonth) . (endedAt ?~ dayOfMonth 10))
          ]
        lineItems <- getBranchDeploymentBillingLineItems 1 startOfMonth endOfMonth repoOwner
        lineItems
          `shouldBeM` [ BranchServerBillingLineItem {group = tierI16x32, includedInPlan = False, usedTime = fromDays @Int 31, cost = usd 120},
                        BranchServerBillingLineItem {group = tierI2x4, includedInPlan = True, usedTime = fromDays @Int 9, cost = usd 0}
                      ]
