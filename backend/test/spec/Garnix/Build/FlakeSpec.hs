module Garnix.Build.FlakeSpec (spec) where

import Garnix.Build.Flake (supersededCancellationScope)
import Garnix.DB (SupersededScope (..))
import Garnix.Prelude
import Garnix.Types
import Test.Hspec

-- | Unit tests for the pure auto-cancel-superseded decision logic. This is
-- deliberately independent of the full build pipeline (no DB, no checkout) so
-- it can be tested directly; the DB-level effects it feeds into
-- ('DB.cancelSupersededWork' -- does the actual cancelling) are covered
-- separately in 'Garnix.DBSpec'.
spec :: Spec
spec = do
  describe "supersededCancellationScope" $ do
    it "never cancels when the feature is off, regardless of branch or fork" $ do
      supersededCancellationScope False (Just "main") Nothing `shouldBe` Nothing
      supersededCancellationScope False Nothing (Just (PrFromFork "someone/fork")) `shouldBe` Nothing
      supersededCancellationScope False Nothing Nothing `shouldBe` Nothing

    it "scopes an ordinary (or non-fork PR) branch push by branch when on" $ do
      supersededCancellationScope True (Just "main") Nothing
        `shouldBe` Just (SupersededBranch "main")

    it "prefers branch scoping even if fork info is somehow also present" $ do
      -- Shouldn't happen for a real CommitInfo, but branch takes precedence:
      -- a real branch on the base repo is the more specific signal.
      supersededCancellationScope True (Just "main") (Just (PrFromFork "someone/fork"))
        `shouldBe` Just (SupersededBranch "main")

    it "scopes a fork PR push (no branch) by fork identity when on" $ do
      supersededCancellationScope True Nothing (Just (PrFromFork "someone/fork"))
        `shouldBe` Just (SupersededFork (PrFromFork "someone/fork"))

    it "is a no-op with neither branch nor fork info even when on" $ do
      supersededCancellationScope True Nothing Nothing `shouldBe` Nothing
