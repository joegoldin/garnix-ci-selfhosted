module Garnix.Build.FlakeSpec (spec) where

import Garnix.Build.Flake (supersededCancellationScope)
import Garnix.DB qualified as DB
import Garnix.Prelude
import Garnix.Types
import Garnix.YamlConfig (autoCancelSuperseded)
import Test.Hspec

-- | Unit tests for the pure auto-cancel-superseded decision logic. This is
-- deliberately independent of the full build pipeline (no DB, no checkout) so
-- it can be tested directly; the DB-level effects it feeds into
-- ('DB.cancelSupersededWork' -- does the actual cancelling) are covered
-- separately in 'Garnix.DBSpec'. The flag now comes entirely from the pushed
-- commit's own parsed 'GarnixConfig' (garnix.yaml) rather than a repo_config
-- lookup, so these tests build a 'GarnixConfig' value directly.
spec :: Spec
spec = do
  describe "supersededCancellationScope" $ do
    it "never cancels when the garnix.yaml flag is off, regardless of branch or fork" $ do
      supersededCancellationScope def (Just "main") Nothing `shouldBe` Nothing
      supersededCancellationScope def Nothing (Just (PrFromFork "someone/fork")) `shouldBe` Nothing
      supersededCancellationScope def Nothing Nothing `shouldBe` Nothing

    it "scopes an ordinary (or non-fork PR) branch push by branch when autoCancelSuperseded is on" $ do
      let config = def & autoCancelSuperseded .~ True
      supersededCancellationScope config (Just "main") Nothing
        `shouldBe` Just (DB.SupersededBranch "main")

    it "prefers branch scoping even if fork info is somehow also present" $ do
      -- Shouldn't happen for a real CommitInfo, but branch takes precedence:
      -- a real branch on the base repo is the more specific signal.
      let config = def & autoCancelSuperseded .~ True
      supersededCancellationScope config (Just "main") (Just (PrFromFork "someone/fork"))
        `shouldBe` Just (DB.SupersededBranch "main")

    it "scopes a fork PR push (no branch) by fork identity when on" $ do
      let config = def & autoCancelSuperseded .~ True
      supersededCancellationScope config Nothing (Just (PrFromFork "someone/fork"))
        `shouldBe` Just (DB.SupersededFork (PrFromFork "someone/fork"))

    it "is a no-op with neither branch nor fork info even when on" $ do
      let config = def & autoCancelSuperseded .~ True
      supersededCancellationScope config Nothing Nothing `shouldBe` Nothing
