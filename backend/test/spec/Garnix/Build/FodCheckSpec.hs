module Garnix.Build.FodCheckSpec (spec) where

import Control.Concurrent qualified as Concurrent
import Control.Concurrent.QSem qualified as QSem
import Control.Lens
import Control.Monad.Trans.Control (liftBaseOp_)
import Control.Retry (limitRetries)
import Cradle
import Data.Aeson.Key qualified as Aeson
import Data.Aeson.KeyMap qualified as Aeson
import Data.Aeson.Lens
import Data.Containers.ListUtils (nubOrd)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Map ((!))
import Data.Map qualified as Map
import Data.String.Interpolate (i)
import Data.String.Interpolate.Util (unindent)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Database.PostgreSQL.Typed (pgSQL)
import Garnix.Build qualified as Build
import Garnix.Build.Checkout (withCheckout)
import Garnix.Build.FodCheck
import Garnix.DB qualified as DB
import Garnix.DB.FeatureFlags.Types
import Garnix.Entitlements qualified as Entitlements
import Garnix.Monad
import Garnix.Monad.Async
import Garnix.Monad.SubProcess (runSubProcess_)
import Garnix.Nix.Types qualified as Nix
import Garnix.NixConfig (addNixConfigEnvironment, nixConfDefaults)
import Garnix.Orchestrator qualified as Orchestrator
import Garnix.Prelude
import Garnix.Reporters.GithubReporter (mkGithubReporter)
import Garnix.Reporters.OpenSearchReporter (openSearchReporter)
import Garnix.TestHelpers
import Garnix.TestHelpers.GithubInterface qualified as GH
import Garnix.TestHelpers.Monad
import Garnix.TestHelpers.Reporter (TestReport (..), withTestReporter_)
import Garnix.Types hiding (context)
import System.IO.Temp (withSystemTempDirectory)
import System.Random (randomIO)
import Test.Hspec
import Test.Mockery.Directory (inTempDirectory)

spec :: Spec
spec = inM $ aroundM_ (withUnmock #fodCheckMock . setUpXdgCacheDir . suppressLogsWhenPassing) $ beforeM_ truncateDBM $ do
  describe "withFodChecker" $ do
    it "disables the FOD check by default" $ do
      GH.withFakeGithubInterface $ \ghState -> do
        GH.withLocalRepo ghState "owner" "repo" identity defaultCommitInfo (GH.simpleSetup "") $ \commitInfo -> do
          withCheckout commitInfo $ do
            plan <- Entitlements.getPlan "owner"
            withFodChecker mempty commitInfo plan $ \fodChecker -> do
              void fodChecker `shouldSatisfyM` isNothing

    it "enables the FOD check in the yaml config" $ do
      GH.withFakeGithubInterface $ \ghState -> do
        let garnixConfig = "fodChecks: true"
        GH.withLocalRepo ghState "owner" "repo" identity defaultCommitInfo (GH.setupWithConfig "" (Just garnixConfig)) $ \commitInfo -> do
          withCheckout commitInfo $ do
            plan <- Entitlements.getPlan "owner"
            withFodChecker mempty commitInfo plan $ \fodChecker -> do
              void fodChecker `shouldSatisfyM` isJust

    it "creates one FOD run when a recovered commit resumes multiple builds" $ do
      GH.withFakeGithubInterface $ \ghState -> do
        void $ DB.newUser "owner" "owner@example.com" FreeSubscription True
        let flake = "{ outputs = { self }: {}; }"
            config = "fodChecks: true"
            publicCommit = defaultCommitInfo & repoPublicity .~ RepoIsPublic True
        GH.withLocalRepo ghState "owner" "repo" identity publicCommit (GH.setupWithConfig flake (Just config)) $ \commitInfo -> do
          let orphan packageName =
                testBuild
                  ( (package .~ packageName)
                      . (gitCommit .~ (commitInfo ^. commit))
                      . (branch .~ (commitInfo ^. branch))
                      . (repoUser .~ "owner")
                      . (repoName .~ "repo")
                      . (reqUser .~ "owner")
                      . (repoIsPublic .~ RepoIsPublic True)
                      . (prFromFork .~ Nothing)
                      . (status .~ Nothing)
                      . (endTime .~ Nothing)
                      . (drvPath ?~ "/nix/store/00000000000000000000000000000000-recovered.drv")
                  )
          firstBuild <- orphan "first"
          secondBuild <- orphan "second"
          map
            (map (^. package))
            ( Orchestrator.groupResumableBuilds
                [ firstBuild,
                  secondBuild,
                  secondBuild & gitCommit .~ "another-commit",
                  secondBuild & reqUser .~ "another-user"
                ]
            )
            `shouldBeM` [["first", "second"], ["second"], ["second"]]
          Build.rerunBuilds mempty [firstBuild, secondBuild & reqUser .~ "another-user"] commitInfo
            `shouldThrowM` OtherError "Cannot share a rerun scope across different commits or authorization contexts"
          withMockReturning #executeDeployPlanMock [] $ do
            withMock
              #buildPkgMock
              ( \(_, _, _, _, _, _, build) -> do
                  now <- liftIO getCurrentTime
                  pure $ build & status ?~ Success & endTime ?~ now
              )
              $ Build.rerunBuilds openSearchReporter [firstBuild, secondBuild] commitInfo
            (length <$> getMockCalls #executeDeployPlanMock) `shouldReturnM` 1

          runs <- DB.getRuns "owner" "repo" (commitInfo ^. commit)
          map (^. status) (filter ((== "FOD checks") . (^. name)) runs)
            `shouldBeM` [Just Success]

  describe "__pickRemoteBuilderUrlFromMachinesFile" $ do
    let realMachinesFile =
          [i|
            ssh-ng://nix-ssh@macMini1 aarch64-darwin,x86_64-darwin /run/secrets/garnix_server_remote_builder_ssh 4 1 big-parallel,recursive-nix - -
            ssh-ng://nix-ssh@macMini2 aarch64-darwin,x86_64-darwin /run/secrets/garnix_server_remote_builder_ssh 4 1 big-parallel,recursive-nix - -
            ssh-ng://nix-ssh@garnix5 x86_64-linux,i686-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
            ssh-ng://nix-ssh@garnix6 x86_64-linux,i686-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
            ssh-ng://nix-ssh@garnix7 x86_64-linux,i686-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
            ssh-ng://nix-ssh@garnix8 x86_64-linux,i686-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
            ssh-ng://nix-ssh@garnix9 x86_64-linux,i686-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
            ssh-ng://nix-ssh@arm-server-0 aarch64-linux /run/secrets/garnix_server_remote_builder_ssh 60 4 nixos-test,kvm,big-parallel,recursive-nix - -
            ssh-ng://nix-ssh@arm-server-1 aarch64-linux /run/secrets/garnix_server_remote_builder_ssh 8 1 nixos-test,kvm,big-parallel,recursive-nix - -
          |]
    let cases =
          [ ( realMachinesFile,
              AArch64Darwin,
              [ "macMini1",
                "macMini2"
              ]
            ),
            ( realMachinesFile,
              X8664Darwin,
              [ "macMini1",
                "macMini2"
              ]
            ),
            ( realMachinesFile,
              X8664Linux,
              [ "garnix5",
                "garnix6",
                "garnix7",
                "garnix8",
                "garnix9"
              ]
            ),
            ( realMachinesFile,
              I686Linux,
              [ "garnix5",
                "garnix6",
                "garnix7",
                "garnix8",
                "garnix9"
              ]
            ),
            ( realMachinesFile,
              OtherSystem "builtin",
              [ "garnix5",
                "garnix6",
                "garnix7",
                "garnix8",
                "garnix9"
              ]
            ),
            ( realMachinesFile,
              AArch64Linux,
              [ "arm-server-0",
                "arm-server-1"
              ]
            )
          ]
    forM_ cases $ \(machinesFile, system, builders) -> do
      it ("picks out a remote builder fairly for " <> cs (system ^. systemTextIso)) $ do
        pickedBuilderUrl <- (sort . nubOrd . catMaybes <$>) $ replicateM 100 $ do
          __pickRemoteBuilderUrlFromMachinesFile system (cs $ unindent machinesFile)
        pickedBuilderUrl `shouldBeM` map (\builder -> "ssh-ng://nix-ssh@" <> builder) builders

    it "returns Nothing when no builder serves the system (self-host rebuilds locally)" $ do
      picked <- __pickRemoteBuilderUrlFromMachinesFile (OtherSystem "riscv64-linux") (cs $ unindent realMachinesFile)
      picked `shouldBeM` Nothing

  describe "__parseMachinesFile" $ do
    let cases =
          [ [i|
              ssh-ng://nix-ssh@foo x86_64-linux,i686-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
              ssh-ng://nix-ssh@bar x86_64-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
            |],
            [i|
              ssh-ng://nix-ssh@foo x86_64-linux,i686-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
              ssh-ng://nix-ssh@bar x86_64-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -

            |],
            [i|
              ssh-ng://nix-ssh@foo x86_64-linux,i686-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
              ssh-ng://nix-ssh@bar x86_64-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -|],
            [i|

              ssh-ng://nix-ssh@foo x86_64-linux,i686-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
              ssh-ng://nix-ssh@bar x86_64-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
            |],
            [i|
              ssh-ng://nix-ssh@foo x86_64-linux,i686-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -

              ssh-ng://nix-ssh@bar x86_64-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
            |],
            [i|
              ssh-ng://nix-ssh@foo x86_64-linux,i686-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
              ssh-ng://nix-ssh@bar    x86_64-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
            |],
            [i|
              ssh-ng://nix-ssh@foo x86_64-linux,i686-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
              ssh-ng://nix-ssh@bar x86_64-linux    /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
            |],
            [i|
              ssh-ng://nix-ssh@foo x86_64-linux,i686-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
               ssh-ng://nix-ssh@bar x86_64-linux /run/secrets/garnix_server_remote_builder_ssh 28 4 nixos-test,kvm,big-parallel,recursive-nix - -
            |]
          ]
    forM_ (zip [0 :: Int ..] cases) $ \(i, machinesFile) -> do
      it ("parses differently formatted machines files (" <> cs (show i) <> ")") $ do
        __parseMachinesFile (cs $ unindent machinesFile)
          `shouldBeM` Right (X8664Linux ~> ["ssh-ng://nix-ssh@bar", "ssh-ng://nix-ssh@foo"] <> I686Linux ~> ["ssh-ng://nix-ssh@foo"])

  describe "__findAllFodsRecursively" $ do
    it "doesn't crash on a real derivation from nixpkgs" $ do
      nixpkgsCommitSha <- getNixpkgsCommitSha
      StdoutRaw output <-
        Cradle.run $ Cradle.cmd "nix"
          & nixConfDefaults
          & Cradle.addArgs
            [ "derivation",
              "show",
              "github:nixos/nixpkgs/"
                <> nixpkgsCommitSha
                <> "#qemu"
            ]
      -- nix < 2.32 puts the drv paths at the JSON top level; newer nix nests
      -- them under "derivations". Accept both.
      let drvsObj = case output ^. key "derivations" . _Object of
            o | not (Aeson.null o) -> o
            _ -> output ^. _Object
      let drvKey = Aeson.toText $ fromSingleton $ Aeson.keys drvsObj
      -- ... and older nix's keys are already absolute store paths.
      let drvPathText = if "/nix/store/" `T.isPrefixOf` drvKey then drvKey else "/nix/store/" <> drvKey
      let drvPath = fromRight $ Nix.parseDrvPath drvPathText
      void $ __findAllFodsRecursively drvPath

  let rebuildFodTestImpl :: (System, Nix.DrvPath) -> M (Either Text Text)
      rebuildFodTestImpl (_system, drvPath) = do
        nixConfig <- view #userNixConfig
        run_
          $ cmd "nix"
          & addArgs ["build", cs drvPath <> "^*", "--no-link" :: Text]
          & addNixConfigEnvironment nixConfig
          & silenceStderr
        (exitCode, StdoutRaw stdout, StderrRaw stderr) <-
          run
            $ cmd "nix"
            & addArgs ["build", cs drvPath <> "^*", "--no-link", "--json", "--rebuild" :: Text]
            & addNixConfigEnvironment nixConfig
            & silenceStderr
        pure $ case exitCode of
          ExitFailure _ -> Left $ cs stderr
          ExitSuccess -> Right $ cs stdout

  describe "__rebuildFod" $ do
    it "prepares an unbuilt FOD before checking it with --rebuild" $ do
      flake <- mkFodFlake Nothing =<< mkRandomOutput
      drvPath <- fst <$> testDerivation flake "fod"
      result <- withUnmock #rebuildFodMock $ __rebuildFod X8664Linux drvPath
      result `shouldSatisfyM` isRight

  describe "__isSourceUnavailableError" $ do
    it "does not trust source-fetch-looking text emitted by a builder" $ do
      __isSourceUnavailableError "curl: (22) The requested URL returned error: 403" `shouldBeM` False
      __isSourceUnavailableError "Exception: Failed to fetch file from https://crates.io. Status code: 403" `shouldBeM` False
      __isSourceUnavailableError "builder failed with exit code 1\n> unable to download policy-sentinel" `shouldBeM` False

    it "does not hide verifier or builder failures" $ do
      __isSourceUnavailableError "some outputs are not valid, so checking is not possible" `shouldBeM` False
      __isSourceUnavailableError "builder failed with exit code 1" `shouldBeM` False
      __isSourceUnavailableError "ssh: connect to host builder: Connection refused" `shouldBeM` False

  describe "__classifyFodBuilder" $ do
    it "accepts executable paths and Nix builtin builders" $ do
      __classifyFodBuilder "/nix/store/00000000000000000000000000000000-bash/bin/bash" `shouldBeM` Nothing
      __classifyFodBuilder "builtin:fetchurl" `shouldBeM` Nothing

    it "diagnoses pre-seeded bootstrap placeholders without treating them as verified" $ do
      let placeholder =
            T.unlines
              [ "#",
                "# Neither your store nor your substituters seems to have:",
                "# /1rz4g4znpzjwh1xymhjpm42vipw92pr73vdgl6xs1hycac8kf2n9",
                "# nix-store --add-fixed --recursive sha256 ./stage0-posix-1.9.1-source",
                "# nix-build '<nixpkgs>' -A make-minimal-bootstrap-sources"
              ]
      __classifyFodBuilder placeholder
        `shouldBeM` Just
          "This fixed-output derivation cannot be independently rebuilt: its builder field is not an executable path or Nix builtin. It may be a pre-seeded bootstrap source supplied only by a substituter. Garnix has not verified it and is failing closed."

      __isBootstrapSeedBuilder placeholder `shouldBeM` True

  describe "__patchCargoVendorBuildPhase" $ do
    it "applies the current nixpkgs crates.io compatibility repair narrowly" $ do
      let buildPhase =
            "runHook preBuild\nfetch-cargo-vendor-util create-vendor-staging ./Cargo.lock \"$out\"\nrunHook postBuild\n"
      let patched = fromRight $ __patchCargoVendorBuildPhase buildPhase
      patched `shouldSatisfyM` T.isInfixOf "478e4912ec6e3325a2d329d9965b5690e08f5138d5008c2ddc12eb76a7a92f98"
      patched `shouldSatisfyM` T.isInfixOf "nixpkgs-fetchCargoVendor/2 (https://github.com/NixOS/nixpkgs)"
      patched `shouldSatisfyM` T.isInfixOf "https://static.crates.io/crates/"
      patched `shouldSatisfyM` T.isInfixOf buildPhase

    it "refuses to rewrite unrelated FOD builders" $ do
      __patchCargoVendorBuildPhase "curl https://example.com > $out"
        `shouldBeM` Left "not a nixpkgs fetchCargoVendor staging build"

  describe "__patchGoVendorFlags" $ do
    it "uses module mode for the complete vendor generation FOD" $ do
      __patchGoVendorFlags "-mod=vendor -trimpath" `shouldBeM` Right "-mod=mod -trimpath"

    it "refuses ambiguous or unrelated Go flags" $ do
      __patchGoVendorFlags "-trimpath" `shouldBeM` Left "Go vendor FOD does not have one unambiguous -mod=vendor flag"

  describe "__remoteStoreArgs" $ do
    it "uses --eval-store only for nix build" $ do
      let url = "ssh-ng://builder@example.test" :: Text
      __remoteStoreArgs False url `shouldBeM` ["--store", url]
      __remoteStoreArgs True url `shouldBeM` ["--store", url, "--eval-store", "auto"]

  describe "remote-store retries" $ do
    it "recognizes the production SSH reset without calling it a fetch failure" $ do
      let stderr =
            "kex_exchange_identification: read: Connection reset by peer\n"
              <> "error: failed to start SSH connection to 'farum-azula-builder'"
      __isRemoteStoreConnectionError stderr `shouldBeM` True
      __isSourceUnavailableError stderr `shouldBeM` False

    it "retries a transient remote-store reset until it succeeds" $ do
      attempts <- liftIO $ newIORef (0 :: Int)
      result <-
        __retryRemoteStoreOperation (limitRetries 3) $ do
          attempt <- liftIO $ atomicModifyIORef' attempts $ \n -> (n + 1, n + 1)
          pure
            $ if attempt < 3
              then Left "error: failed to start SSH connection to 'builder'"
              else Right ("verified" :: Text)
      result `shouldBeM` Right "verified"
      liftIO (readIORef attempts) `shouldReturnM` 3

    it "does not retry source-fetch or builder failures" $ do
      attempts <- liftIO $ newIORef (0 :: Int)
      result <-
        __retryRemoteStoreOperation (limitRetries 3) $ do
          liftIO $ atomicModifyIORef' attempts $ \n -> (n + 1, ())
          pure (Left "curl: (22) The requested URL returned error: 403" :: Either Text Text)
      result `shouldBeM` Left "curl: (22) The requested URL returned error: 403"
      liftIO (readIORef attempts) `shouldReturnM` 1

    it "stops after the configured number of remote-store retries" $ do
      attempts <- liftIO $ newIORef (0 :: Int)
      result <-
        __retryRemoteStoreOperation (limitRetries 3) $ do
          liftIO $ atomicModifyIORef' attempts $ \n -> (n + 1, ())
          pure (Left "ssh: connect to host builder: Connection refused" :: Either Text Text)
      result `shouldBeM` Left "ssh: connect to host builder: Connection refused"
      liftIO (readIORef attempts) `shouldReturnM` 4

  describe "remote-store concurrency" $ do
    it "holds a one-job slot across each complete remote FOD transaction" $ do
      slots <- liftIO $ QSem.newQSem 1
      trace <- liftIO $ newIORef ([] :: [Int])
      let phase transactionId = liftIO $ do
            atomicModifyIORef' trace $ \xs -> (xs <> [transactionId], ())
            Concurrent.threadDelay 10000
          transaction transactionId =
            __runRemoteFodTransaction slots (phase transactionId) (phase transactionId) (phase transactionId)
      forConcurrently_ [1, 2 :: Int] transaction
      observed <- liftIO $ readIORef trace
      observed `shouldSatisfyM` (`elem` [[1, 1, 1, 2, 2, 2], [2, 2, 2, 1, 1, 1]])

    it "releases the remote FOD slot when a transaction throws" $ do
      slots <- liftIO $ QSem.newQSem 1
      __runRemoteFodTransaction slots (throw $ OtherError "copy failed") (pure ()) (pure ())
        `shouldThrowM` OtherError "copy failed"
      __runRemoteFodTransaction slots (pure ()) (pure ()) (pure ("next" :: Text))
        `shouldReturnM` ("next" :: Text)

  describe "fodCheck" $ aroundM_ (withMock #rebuildFodMock rebuildFodTestImpl) $ do
    let test :: Nix.DrvPath -> M TestReport
        test drvPath = do
          let garnixConfig = "fodChecks: true"
          dir <- view #workingDir
          liftIO $ T.writeFile (dir </> "garnix.yaml") garnixConfig
          result <- withTestReporter_ $ \reporter -> do
            plan <- Entitlements.getPlan "owner"
            withFodChecker reporter defaultCommitInfo plan $ \fodChecker -> do
              void fodChecker `shouldSatisfyM` isJust
              fodCheck fodChecker drvPath
          pure $ result ! "FOD checks"

    it "does not fail for benign fods" $ do
      flake <- mkFodFlake Nothing =<< mkRandomOutput
      drvPath <- fst <$> testDerivation flake "default"
      buildDrvPath drvPath
      report <- test drvPath
      fodDrvPath <- fst <$> testDerivation flake "fod"
      (report ^. #success) `shouldBeM` Just True
      report ^. #logs `shouldBeM` "Checking fixed output derivations...\n1 FOD was verified."
      verifiedFodsShouldBe [fodDrvPath]

    it "fails closed when a FOD source cannot be re-fetched" $ do
      -- Fetch diagnostics are emitted by the FOD's own builder and therefore
      -- are not authenticated verifier provenance. A builder can print a
      -- fetch-looking 403 itself, so any failed strict rebuild must fail the
      -- security gate rather than becoming a non-blocking skip.
      fod <- mkFodFlake Nothing =<< mkRandomOutput
      drvPath <- fst <$> testDerivation fod "fod"
      report <-
        withMock
          #rebuildFodMock
          (\(_ :: (System, Nix.DrvPath)) -> pure (Left "curl: (22) The requested URL returned error: 403" :: Either Text Text))
          $ test drvPath
      (report ^. #success) `shouldBeM` Just False
      let logs = cs (report ^. #logs) :: String
      logs `shouldContainM` "Failure when checking FOD"
      logs `shouldNotContainM` "source could not be fetched"
      verifiedFodsShouldBe []

    it "fails instead of calling a checker error source-unavailable" $ do
      fod <- mkFodFlake Nothing =<< mkRandomOutput
      drvPath <- fst <$> testDerivation fod "fod"
      report <-
        withMock
          #rebuildFodMock
          ( \(_ :: (System, Nix.DrvPath)) ->
              pure
                ( Left
                    "error: some outputs are not valid, so checking is not possible\nHint: --rebuild and --check error if the derivation was not previously built" ::
                    Either Text Text
                )
          )
          $ test drvPath
      (report ^. #success) `shouldBeM` Just False
      let logs = cs (report ^. #logs) :: String
      logs `shouldContainM` "Failure when checking FOD"
      logs `shouldNotContainM` "source could not be fetched"
      verifiedFodsShouldBe []

    it "fails for lying fods" $ do
      output <- mkRandomOutput
      validButMalicious <- mkFodFlake Nothing output
      buildDrvPath . fst =<< testDerivation validButMalicious "default"
      lying <- mkFodFlake Nothing (output & #output .~ "bar")
      lyingDrvPath <- fst <$> testDerivation lying "default"
      report <- test lyingDrvPath
      (report ^. #success) `shouldBeM` Just False
      (report ^. #logs) `shouldSatisfyM` T.isInfixOf "hash mismatch in fixed-output derivation"

    it "works for benign fods that weren't built yet" $ do
      flake <- mkFodFlake Nothing =<< mkRandomOutput
      drvPath <- fst <$> testDerivation flake "default"
      report <- test drvPath
      (report ^. #success) `shouldBeM` Just True
      fodDrvPath <- fst <$> testDerivation flake "fod"
      report ^. #logs `shouldBeM` "Checking fixed output derivations...\n1 FOD was verified."
      verifiedFodsShouldBe [fodDrvPath]

    it "doesn't fail for fods that have different build scripts, but produce the same result" $ do
      output <- mkRandomOutput
      fodA <- mkFodFlake (Just "echo a") output
      drvPathA <- fst <$> testDerivation fodA "default"
      buildDrvPath drvPathA
      report <- test drvPathA
      (report ^. #success) `shouldBeM` Just True
      fodB <- mkFodFlake (Just "echo b") output
      drvPathB <- fst <$> testDerivation fodB "default"
      buildDrvPath drvPathB
      report <- test drvPathB
      (report ^. #success) `shouldBeM` Just True

    it "fails for lying fods after verifying other fods" $ do
      output <- mkRandomOutput
      fod <- mkFodFlake Nothing output
      drvPath <- fst <$> testDerivation fod "default"
      buildDrvPath drvPath
      report <- test drvPath
      (report ^. #success) `shouldBeM` Just True
      validButMalicious <- mkFodFlake Nothing output
      buildDrvPath . fst =<< testDerivation validButMalicious "default"
      lying <- mkFodFlake Nothing (output & #output .~ "bar")
      lyingDrvPath <- fst <$> testDerivation lying "default"
      report <- test lyingDrvPath
      (report ^. #success) `shouldBeM` Just False
      (report ^. #logs) `shouldSatisfyM` T.isInfixOf "hash mismatch in fixed-output derivation"

    it "adds verified fods into the db" $ do
      fod <- mkFodFlake Nothing =<< mkRandomOutput
      (drvPath, storePath) <- testDerivation fod "fod"
      buildDrvPath drvPath
      buildDrvPath . fst =<< testDerivation fod "default"
      report <- test drvPath
      (report ^. #success) `shouldBeM` Just True
      getVerifiedFods
        `shouldReturnM` [ ( Nix.getStoreHash $ Nix.getHash $ Nix.getDrvPath drvPath,
                            Nix.getStoreHash $ Nix.getHash storePath
                          )
                        ]

    it "doesn't add lying fods into the db" $ do
      output <- mkRandomOutput
      validButMalicious <- mkFodFlake Nothing output
      buildDrvPath . fst =<< testDerivation validButMalicious "default"
      lying <- mkFodFlake Nothing (output & #output .~ "bar")
      lyingDrvPath <- fst <$> testDerivation lying "default"
      report <- test lyingDrvPath
      (report ^. #success) `shouldBeM` Just False
      getVerifiedFods `shouldReturnM` []

    it "doesn't recheck already verified fods" $ do
      output <- mkRandomOutput
      validButMalicious <- mkFodFlake Nothing output
      buildDrvPath . fst =<< testDerivation validButMalicious "default"
      lying <- mkFodFlake Nothing (output & #output .~ "bar")
      (lyingDrvPath, lyingStorePath) <- testDerivation lying "fod"
      DB.addVerifiedFod lyingDrvPath lyingStorePath
      report <- test lyingDrvPath
      (report ^. #success) `shouldBeM` Just True

    it "does not run the fod check if it is not enabled" $ do
      result <- withTestReporter_ $ \reporter -> do
        let commitInfo =
              defaultCommitInfo
                & repoInfo . ghRepoOwner .~ "owner"
                & repoInfo . ghRepoName .~ "repo"
                & reqUser .~ "owner"
        output <- mkRandomOutput
        validButMalicious <- mkFodFlake Nothing output
        buildDrvPath . fst =<< testDerivation validButMalicious "default"
        lying <- mkFodFlake Nothing (output & #output .~ "bar")
        lyingDrvPath <- fst <$> testDerivation lying "default"
        plan <- Entitlements.getPlan "owner"
        withFodChecker reporter commitInfo plan $ \fodChecker -> do
          fodCheck fodChecker lyingDrvPath
      result `shouldBeM` mempty

    it "reports the correct final status" $ do
      lyingDrvPath <- do
        -- fast bad FOD
        output <- mkRandomOutput
        validButMaliciousFlake <- mkFodFlake Nothing output
        buildDrvPath . fst =<< testDerivation validButMaliciousFlake "default"
        lying <- mkFodFlake Nothing (output & #output .~ "bar")
        fst <$> testDerivation lying "fod"
      successDrvPath <- do
        -- slow good FOD
        output <- mkRandomOutput
        successFlake <- mkFodFlake (Just "sleep 5") output
        buildDrvPath . fst =<< testDerivation successFlake "default"
        fst <$> testDerivation successFlake "fod"
      reports <- do
        let garnixConfig = "fodChecks: true"
        dir <- view #workingDir
        liftIO $ T.writeFile (dir </> "garnix.yaml") garnixConfig
        withTestReporter_ $ \reporter -> do
          plan <- Entitlements.getPlan "owner"
          withFodChecker reporter defaultCommitInfo plan $ \fodChecker -> do
            fodCheck fodChecker lyingDrvPath
            fodCheck fodChecker successDrvPath
      (reports ! "FOD checks") ^. #success `shouldBeM` Just False
      let logs = cs $ (reports ! "FOD checks") ^. #logs
      logs `shouldContainM` "1 FOD was verified."
      logs `shouldContainM` ("Failure when checking FOD '" <> cs lyingDrvPath <> "':\n")
      verifiedFodsShouldBe [successDrvPath]

    it "deduplicates fod checks running within the same `FodChecker`" $ do
      drvPath <- do
        output <- mkRandomOutput
        flake <- mkFodFlake Nothing output
        buildDrvPath . fst =<< testDerivation flake "default"
        fst <$> testDerivation flake "fod"
      reports <- do
        let garnixConfig = "fodChecks: true"
        dir <- view #workingDir
        liftIO $ T.writeFile (dir </> "garnix.yaml") garnixConfig
        withTestReporter_ $ \reporter -> do
          plan <- Entitlements.getPlan "owner"
          withFodChecker reporter defaultCommitInfo plan $ \fodChecker -> do
            fodCheck fodChecker drvPath
            fodCheck fodChecker drvPath
      (reports ! "FOD checks") ^. #success `shouldBeM` Just True
      let logs = (reports ! "FOD checks") ^. #logs
      logs `shouldBeM` "Checking fixed output derivations...\n1 FOD was verified."
      verifiedFodsShouldBe [drvPath]

    context "testing through `handleCommit`" $ do
      aroundM_ (withFeatureFlags (FeatureFlagConfigDbo (Map.toList (FodChecks ~> Percentage 100)))) $ do
        let config =
              cs
                $ unindent
                  [i|
                    builds:
                      include:
                        - "*.x86_64-linux.default"
                  |]
        it "logs a Error error on lying fods" $ GH.withFakeGithubInterface $ \ghState -> do
          output <- mkRandomOutput
          validButMalicious <- mkFodFlake Nothing output
          buildDrvPath . fst =<< testDerivation validButMalicious "default"
          lying <- mkFodFlake Nothing (output & #output .~ "bar")
          GH.withLocalRepo ghState "owner" "repo" identity defaultCommitInfo (GH.setupWithConfig lying (Just config)) $ \commitInfo -> do
            logs <- captureLogs_ $ resolve =<< Orchestrator.handleCommit mempty True commitInfo
            let errorLogs = filter (\logItem -> (logItem ^. #severity) == Error) logs
            let log = cs $ msg $ fromSingleton errorLogs
            lyingDerivation <- fst <$> testDerivation lying "fod"
            log `shouldContainM` ("hash mismatch in fixed-output derivation '" <> cs lyingDerivation <> "'")
            log `shouldContainM` ("specified: " <> cs (output ^. #outputHash) <> "\n")
            barOutputHash <- getOutputHash "bar"
            log `shouldContainM` ("got:    " <> cs barOutputHash <> "\n")

        it "doesn't interfere with new (unbuilt) benign fods" $ GH.withFakeGithubInterface $ \ghState -> do
          output <- mkRandomOutput
          flake <- mkFodFlake Nothing output
          void $ testDerivation flake "default"
          GH.withLocalRepo ghState "owner" "repo" identity defaultCommitInfo (GH.setupWithConfig flake (Just config)) $ \commitInfo -> do
            criticalLog <-
              captureLogs_ (resolve =<< Orchestrator.handleCommit mempty True commitInfo)
                <&> filter (\logItem -> (logItem ^. #severity) == Error)
            criticalLog `shouldBeM` []

      it "creates a CI check when enabled" $ GH.withFakeGithubInterface $ \ghState -> do
        output <- mkRandomOutput
        flake <- mkFodFlake Nothing output
        (drvPath, _) <- testDerivation flake "default"
        buildDrvPath drvPath
        let garnixConfig = "fodChecks: true"
        GH.withLocalRepo ghState "owner" "repo" identity defaultCommitInfo (GH.setupWithConfig flake (Just garnixConfig)) $ \commitInfo -> do
          let reporter = mkGithubReporter (commitInfo ^. repoInfo) (commitInfo ^. commit)
          resolve =<< Orchestrator.handleCommit reporter True commitInfo
          (fodDrv, _) <- testDerivation flake "fod"
          verifiedFodsShouldBe [fodDrv]

setUpXdgCacheDir :: M a -> M a
setUpXdgCacheDir action = withSystemTempDirectory "garnix-xdg-cache-dir" $ \dir ->
  local (#nixXdgCacheDir ?~ dir) action

data TestOutput = TestOutput
  { output :: Text,
    outputHash :: Text
  }
  deriving (Generic, Show)

mkRandomOutput :: (MonadIO m) => m TestOutput
mkRandomOutput = do
  n :: Int <- randomIO
  let output = show n
  hash <- getOutputHash output
  pure $ TestOutput output hash

getOutputHash :: (MonadIO m) => Text -> m Text
getOutputHash output =
  liftIO $ inTempDirectory $ do
    T.writeFile "file" (output <> "\n")
    StdoutTrimmed (hash :: Text) <-
      run
        $ cmd "nix"
        & addArgs (T.words "hash path file --base64")
        & nixConfDefaults
    pure ("sha256-" <> hash)

mkFodFlake :: Maybe Text -> TestOutput -> M Text
mkFodFlake fodCommand testOutput = do
  let hash = testOutput ^. #outputHash
  let out = testOutput ^. #output
  pure
    $ cs
    $ unindent
      [i|
        {
          outputs = {...} : {
            packages.x86_64-linux = rec {
              fod = derivation {
                name = "fod";
                system = "x86_64-linux";
                outputHashMode = "recursive";
                outputHashAlgo = "sha256";
                outputHash = "#{hash}";
                builder = "/bin/sh";
                args = ["-c" "#{fromMaybe "" fodCommand}\necho #{out} > $out"];
              };
              default = derivation {
                name = "depends-on-fod-at-build-time";
                system = "x86_64-linux";
                builder = "/bin/sh";
                args = ["-c" "# ${fod}\necho > $out"];
              };
            };
          };
        }
      |]

testDerivation :: Text -> Text -> M (Nix.DrvPath, Nix.StorePath)
testDerivation flake packageName = do
  liftBaseOp_ inTempDirectory $ do
    liftIO $ T.writeFile "flake.nix" flake
    StdoutTrimmed output <-
      run
        $ cmd "nix"
        & addArgs
          [ "eval",
            -- This fixture is an ordinary path flake. A bare .# reference can
            -- be captured by an unrelated parent Git repository (notably
            -- /tmp/.git under sandboxed test runners on Nix 2.34).
            "path:.#" <> packageName,
            "--apply",
            "x : {storePath = builtins.toString x; drvPath = x.drvPath; }",
            "--json" :: Text
          ]
        & nixConfDefaults
    let drvPath = Nix.DrvPath $ fromRight $ Nix.parseStorePath (output ^. key "drvPath" . _String)
    let storePath = fromRight $ Nix.parseStorePath (output ^. key "storePath" . _String)
    pure (drvPath, storePath)

buildDrvPath :: Nix.DrvPath -> M ()
buildDrvPath drvPath = do
  runSubProcess_
    $ cmd "nix"
    & addArgs ["build", (cs drvPath <> "^*") :: Text]
    & nixConfDefaults

getVerifiedFods :: M [(Text, Text)]
getVerifiedFods =
  DB.pgQuery
    [pgSQL| SELECT drv_hash, store_path_hash FROM verified_fods; |]

verifiedFodsShouldBe :: [Nix.DrvPath] -> M ()
verifiedFodsShouldBe drvPaths =
  (map fst <$> getVerifiedFods) `shouldReturnM` fmap (cs . Nix.getHash . Nix.getDrvPath) drvPaths
