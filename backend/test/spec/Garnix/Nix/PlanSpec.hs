module Garnix.Nix.PlanSpec (spec) where

import Cradle
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.Map.Strict qualified as Map
import Garnix.Monad (M)
import Garnix.Nix.Plan
import Garnix.Nix.Types
import Garnix.Prelude
import Garnix.TestHelpers.Monad
import Test.Hspec

spec :: Spec
spec = inM $ aroundM_ suppressLogsWhenPassing $ do
  describe "getPlanOf" $ do
    it "keeps a deferred derivation whose output path is not known yet"
      $ withDerivation "mk { input = ca; }"
      $ \drv -> do
        plan <- getPlanOf $ cs $ "this derivation will be built:\n  " <> drv <> "\n"
        planDrvPaths plan `shouldBeM` [asDrvPath drv]
        planOutputs plan `shouldBeM` []

    it "keeps known output paths"
      $ withDerivation "mk {}"
      $ \drv -> do
        StdoutTrimmed output <- run $ cmd "nix-store" & addArgs ["--query", "--outputs", drv]
        plan <- getPlanOf $ cs $ "this derivation will be built:\n  " <> drv <> "\n"
        planOutputs plan `shouldBeM` [asStorePath output]

    it "keeps floating content-addressed derivations"
      $ withDerivation "ca"
      $ \drv -> do
        plan <- getPlanOf $ cs $ "this derivation will be built:\n  " <> drv <> "\n"
        planDrvPaths plan `shouldBeM` [asDrvPath drv]
        planOutputs plan `shouldBeM` []

    it "keeps versioned dynamic derivations"
      $ withDerivation "mk { input = builtins.outputOf ca.outPath \"out\"; }"
      $ \drv -> do
        plan <- getPlanOf $ cs $ "this derivation will be built:\n  " <> drv <> "\n"
        planDrvPaths plan `shouldBeM` [asDrvPath drv]
        planOutputs plan `shouldBeM` []

    it "preserves order and known outputs in a mixed plan"
      $ withDerivation "mk {}"
      $ \known -> withDerivation "mk { input = ca; }" $ \deferred -> do
        StdoutTrimmed output <- run $ cmd "nix-store" & addArgs ["--query", "--outputs", known]
        plan <- getPlanOf $ cs $ "these 2 derivations will be built:\n  " <> deferred <> "\n  " <> known <> "\n"
        planDrvPaths plan `shouldBeM` [asDrvPath deferred, asDrvPath known]
        planOutputs plan `shouldBeM` [asStorePath output]

    it "does not invoke derivation lookup for a fetch-only plan" $ do
      plan <- getPlanOf "these paths will be fetched:\n  /nix/store/00000000000000000000000000000000-fetched\n"
      planDrvPaths plan `shouldBeM` []
      planOutputs plan `shouldBeM` []

  describe "_parsePlanOutputs" $ do
    let drv = "00000000000000000000000000000000-plan.drv"
        output = "00000000000000000000000000000000-plan"
        definition path = Aeson.object ["outputs" Aeson..= Aeson.object ["out" Aeson..= Aeson.object ["path" Aeson..= path]]]
        decode = Aeson.parseEither _parsePlanOutputs
        expected = Right $ Map.singleton (asDrvPath $ "/nix/store/" <> drv) [asStorePath $ "/nix/store/" <> output]
    it "accepts the legacy map and relative output paths"
      $ decode (Aeson.object [fromString (cs $ "/nix/store/" <> drv) Aeson..= definition output])
      `shouldBeM` expected
    it "accepts the versioned wrapper and absolute output paths"
      $ decode (Aeson.object ["version" Aeson..= (4 :: Int), "derivations" Aeson..= Aeson.object [fromString (cs drv) Aeson..= definition ("/nix/store/" <> output)]])
      `shouldBeM` expected
    it "rejects missing outputs instead of treating them as unknown paths"
      $ decode (Aeson.object [fromString (cs drv) Aeson..= Aeson.object []])
      `shouldSatisfyM` isLeft
    it "rejects invalid output paths"
      $ decode (Aeson.object [fromString (cs drv) Aeson..= definition ("/tmp/not-a-store-path" :: Text)])
      `shouldSatisfyM` isLeft

withDerivation :: Text -> (Text -> M a) -> M a
withDerivation expression action = do
  let fixture =
        "let mk = attrs: derivation ({ name = \"plan-test\"; builder = \"/bin/sh\"; system = builtins.currentSystem; } // attrs); "
          <> "ca = mk { name = \"plan-ca\"; __contentAddressed = true; outputHashAlgo = \"sha256\"; outputHashMode = \"recursive\"; }; in "
          <> expression
  StdoutTrimmed drv <-
    run
      $ cmd "nix-instantiate"
      & addArgs ["--extra-experimental-features", "ca-derivations dynamic-derivations", "--expr", fixture]
  action drv

asStorePath :: Text -> StorePath
asStorePath = either error identity . parseStorePath

asDrvPath :: Text -> DrvPath
asDrvPath = DrvPath . asStorePath
