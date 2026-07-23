module Garnix.Hosting.BudgetSpec (spec) where

import Garnix.Hosting.Budget
import Garnix.Hosting.ServerPool.Types
import Garnix.Prelude
import Test.Hspec

spec :: Spec
spec = do
  describe "tier resource model" $ do
    it "sums count-weighted tier resources" $
      sumTierResources [(I2x4, 2), (I1x1, 1)]
        `shouldBe` Committed {committedVcpus = 2 * 2 + 1, committedMiB = 2 * 4096 + 1024}

    it "fits when both dims stay within the caps" $
      fitsBudget (ResourceBudget (Just 4) (Just 8192)) (Committed 2 4096) I2x4 `shouldBe` True

    it "rejects when the memory cap would be exceeded" $
      fitsBudget (ResourceBudget (Just 8) (Just 6144)) (Committed 2 4096) I2x4 `shouldBe` False

    it "rejects when the vcpu cap would be exceeded" $
      fitsBudget (ResourceBudget (Just 3) (Just 65536)) (Committed 2 4096) I2x4 `shouldBe` False

    it "an unset cap always fits that dimension" $
      fitsBudget (ResourceBudget Nothing Nothing) (Committed 999 999999) I16x32 `shouldBe` True

  describe "budget env parsing" $ do
    it "parses an absolute budget" $
      parseBudget "total:65536" `shouldBe` Just (Absolute 65536)
    it "parses a reserve budget" $
      parseBudget "reserve:81920" `shouldBe` Just (Reserve 81920)
    it "rejects malformed input" $
      parseBudget "80G" `shouldBe` Nothing

  describe "reserve resolution" $ do
    it "absolute passes through" $
      resolveBudget 128000 (Just (Absolute 65536)) `shouldBe` Just 65536
    it "reserve subtracts from the host total" $
      resolveBudget 128000 (Just (Reserve 81920)) `shouldBe` Just (128000 - 81920)
    it "reserve never goes negative" $
      resolveBudget 1024 (Just (Reserve 4096)) `shouldBe` Just 0
    it "unset stays unbounded" $
      resolveBudget 128000 Nothing `shouldBe` Nothing
