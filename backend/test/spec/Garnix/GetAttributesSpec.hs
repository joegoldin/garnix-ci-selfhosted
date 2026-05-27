{-# LANGUAGE QuasiQuotes #-}

module Garnix.GetAttributesSpec (spec) where

import Control.Lens ((^?!))
import Data.String.Interpolate (i)
import Garnix.Attribute
import Garnix.Build.Helpers (withPrivateNixXdgCache)
import Garnix.GetAttributes (getAttributesToBuild)
import Garnix.Monad (M, throw)
import Garnix.Prelude
import Garnix.TestHelpers (defaultCommitInfo)
import Garnix.TestHelpers.GithubInterface qualified as GH
import Garnix.TestHelpers.Monad
import Garnix.TestInstances ()
import Garnix.Types hiding (context)
import Garnix.Types qualified as Types
import Garnix.YamlConfig (decodeConfig)
import Test.Hspec

spec :: Spec
spec = do
  describe "asAttribute" $ do
    let (?=) :: (HasCallStack) => Text -> Attribute -> Spec
        a ?= b = do
          it ("parses '" <> cs a <> "' correctly")
            $ a
            ^? asAttribute
            `shouldBe` Just b
          it ("prints '" <> cs a <> "' correctly")
            $ review asAttribute b
            `shouldBe` a
    "homeConfigurations.foo" ?= homeConfigurationAttr "foo"
    "darwinConfigurations.foo" ?= darwinConfigurationAttr "foo"
    "nixosConfigurations.foo" ?= nixosConfigurationAttr "foo"
    "checks.x86_64-linux.foo" ?= checkAttr X8664Linux "foo"
    "devShell.x86_64-linux" ?= defaultDevShellAttr X8664Linux
    "defaultPackage.x86_64-linux" ?= defaultPackageAttr X8664Linux
    "packages.x86_64-linux" ?= packagesAttr X8664Linux
    "homeConfigurations.foo.more.nested.things"
      ?= (homeConfigurationAttr "foo" & extension ?~ "more.nested.things")
    "nixosConfigurations.foo.more.nested.things"
      ?= (nixosConfigurationAttr "foo" & extension ?~ "more.nested.things")

  inM $ describe "getAttributesToBuild" $ do
    it "defaults with an empty config" $ do
      let cfg = ""
          flake =
            [i|
              {
                outputs = { self }: {
                  packages.x86_64-linux.bar = {};
                  packages.x86_64-linux.foo = {};
                };
              }
            |]
      attrs <- testGetAttributes cfg flake
      attrs
        `shouldBeM` [ "packages.x86_64-linux.bar" ^?! asAttribute,
                      "packages.x86_64-linux.foo" ^?! asAttribute
                    ]

    it "by default only includes x86_64-linux" $ do
      let cfg = ""
          flake =
            [i|
              {
                outputs = { self }: {
                  packages.x86_64-linux.foo = {};
                  packages.aarch64-linux.foo = {};
                  packages.x86_64-darwin.foo = {};
                  packages.aarch64-darwin.foo = {};
                };
              }
            |]
      attrs <- testGetAttributes cfg flake
      attrs
        `shouldBeM` [ "packages.x86_64-linux.foo" ^?! asAttribute
                    ]

    it "only builds packages in include if defined" $ do
      let cfg =
            [i|
              builds:
                include:
                  - "packages.*.bar"
            |]
          flake =
            [i|
              {
                outputs = { self }: {
                  packages.x86_64-linux.bar = {};
                  packages.x86_64-linux.foo = {};
                };
              }
            |]
      attrs <- testGetAttributes cfg flake
      attrs
        `shouldBeM` [ "packages.x86_64-linux.bar" ^?! asAttribute
                    ]

    it "omits packages in exclude" $ do
      let cfg =
            [i|
              builds:
                exclude:
                  - "packages.*.bar"
            |]
          flake =
            [i|
              {
                outputs = { self }: {
                  packages.x86_64-linux.bar = {};
                  packages.x86_64-linux.foo = {};
                };
              }
            |]
      attrs <- testGetAttributes cfg flake
      attrs
        `shouldBeM` [ "packages.x86_64-linux.foo" ^?! asAttribute
                    ]

    it "exclude takes precedence" $ do
      let cfg =
            [i|
              builds:
                include:
                  - "packages.aarch64-linux.*"
                exclude:
                  - "packages.aarch64-linux.bar"
            |]
          flake =
            [i|
              {
                outputs = { self }: {
                  packages.aarch64-linux.bar = {};
                  packages.aarch64-linux.foo = {};
                };
              }
            |]
      attrs <- testGetAttributes cfg flake
      attrs
        `shouldBeM` [ "packages.aarch64-linux.foo" ^?! asAttribute
                    ]

    it "handles multiple build sections" $ do
      let cfg =
            [i|
              builds:
                - include: ["packages.*.*"]
                  exclude: ["packages.*.foo"]
                - include: ["packages.*.foo"]
            |]
          flake =
            [i|
              {
                outputs = { self }: {
                  packages.aarch64-linux.bar = {};
                  packages.aarch64-linux.foo = {};
                };
              }
            |]
      attrs <- testGetAttributes cfg flake
      attrs
        `shouldBeM` [ "packages.aarch64-linux.bar" ^?! asAttribute,
                      "packages.aarch64-linux.foo" ^?! asAttribute
                    ]

    it "supports using branch names to apply relevant build sections" $ do
      let cfg =
            [i|
              builds:
                - include: ["packages.*.*"]
                  exclude: ["packages.*.foo", "packages.*.bar"]
                - include: ["packages.*.foo"]
                  branch: feature1
                - include: ["packages.*.bar"]
                  branch: feature2
            |]
          flake =
            [i|
              {
                outputs = { self }: {
                  packages.aarch64-linux.bar = {};
                  packages.aarch64-linux.baz = {};
                  packages.aarch64-linux.foo = {};
                };
              }
            |]
      attrs <- testGetAttributes cfg flake
      attrs
        `shouldBeM` [ "packages.aarch64-linux.baz" ^?! asAttribute,
                      "packages.aarch64-linux.foo" ^?! asAttribute
                    ]

testGetAttributes :: String -> String -> M [Attribute]
testGetAttributes cfg flake = do
  garnixConfig <- either (throw . OtherError . cs) pure $ decodeConfig (cs cfg)
  GH.withFakeGithubInterface $ \ghState -> do
    let commitInfo = defaultCommitInfo & Types.branch . _Just .~ "feature1"
    GH.withLocalRepo ghState "owner" "repo" identity commitInfo (GH.simpleSetup (cs flake)) $ \commitInfo -> do
      testRepo <- GH.lookupRepo ghState "owner" "repo"
      local (#workingDir .~ (testRepo ^. _Just . #localPath . _Just)) $ do
        suppressLogs $ withPrivateNixXdgCache $ do
          getAttributesToBuild commitInfo garnixConfig

homeConfigurationAttr :: PackageName -> Attribute
homeConfigurationAttr n = homeConfigurationsAttr & packageName ?~ n

darwinConfigurationAttr :: PackageName -> Attribute
darwinConfigurationAttr n = darwinConfigurationsAttr & packageName ?~ n

nixosConfigurationAttr :: PackageName -> Attribute
nixosConfigurationAttr n = nixosConfigurationsAttr & packageName ?~ n
