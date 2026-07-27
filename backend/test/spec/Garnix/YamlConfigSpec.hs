module Garnix.YamlConfigSpec (spec) where

import Autodocodec (HasCodec, eitherDecodeJSONViaCodec, encodeJSONViaCodec, parseJSONViaCodec)
import Data.Aeson qualified as Aeson
import Data.Aeson.Lens (key, nth)
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.String.Interpolate
import Data.String.Interpolate.Util
import Data.Yaml qualified as Yaml
import Garnix.Build.Checkout (remoteWithConfig, runWithCheckout)
import Garnix.Hosting.ServerPool.Types
import Garnix.Prelude
import Garnix.TestHelpers (defaultCommitInfo, fromSingleton)
import Garnix.TestHelpers.GithubInterface qualified as GH
import Garnix.TestHelpers.Monad
import Garnix.Types hiding (context, logFile, pending)
import Garnix.YamlConfig
import Test.Hspec

-- | Decode a single yaml @servers:@ list entry directly into 'ServerSection'
-- via its own 'HasCodec' instance — 'GarnixConfig' no longer carries a
-- `servers` field at all (§3: it moved into nixosConfigurations), but
-- 'ServerSection' itself is unchanged (it's the decode target
-- 'Garnix.YamlConfig.decodeDeploySpec' now produces from a nix
-- `garnix.server.deploySpec`), so its own codec fidelity is still worth
-- testing directly. Fixtures below keep their original `servers:\n  - ...`
-- shape for a minimal diff; this just reaches into `servers[0]` instead of
-- going through 'decodeConfig'.
decodeServerSection :: ByteString -> Either String ServerSection
decodeServerSection bytes = do
  value <- first (cs . show) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Aeson.Value)
  case value ^? key "servers" . nth 0 of
    Nothing -> Left "expected a servers[0] entry in the fixture"
    Just v -> parseEither parseJSONViaCodec v

spec :: Spec
spec = do
  describe "the config" $ do
    let defaultConfig =
          cs
            [i|
              builds:
                - include:
                    - "*.x86_64-linux.*"
                    - "defaultPackage.x86_64-linux"
                    - "devShell.x86_64-linux"
                    - "homeConfigurations.*"
                    - "darwinConfigurations.*"
                    - "nixosConfigurations.*"
                  exclude: []

              incrementalizeBuilds: false

              fodChecks: false
            |]
    it "parses the empty config to the default config"
      $ decodeConfig ""
      `shouldBe` Right def

    it "parses the empty object to the default config"
      $ decodeConfig "{}"
      `shouldBe` decodeConfig defaultConfig

    describe "build section" $ do
      let simpleConfig =
            cs
              [i|
                builds:
                  include:
                    - "*.*.*"
                    - "*.*"
                  exclude:
                    - "*.x86_64-linux.*"
              |]
      it "parses the excludes section" $ do
        let actual =
              (^. buildSections . to fromSingleton . excludeSection)
                <$> decodeConfig simpleConfig
        actual `shouldBe` Right [AttributeMatcher "*" "x86_64-linux" (Just "*")]

      it "parses the includes section" $ do
        let actual =
              (^. buildSections . to fromSingleton . includeSection)
                <$> decodeConfig simpleConfig
        actual
          `shouldBe` Right
            [ AttributeMatcher "*" "*" (Just "*"),
              AttributeMatcher "*" "*" Nothing
            ]

      it "parses home-, darwin- and nixosConfigurations" $ do
        let config =
              cs
                [i|
                  builds:
                    include:
                      - homeConfigurations.*
                      - darwinConfigurations.foo
                    exclude:
                      - nixosConfigurations.*
                |]
            Right actual =
              (^. buildSections . to fromSingleton)
                <$> decodeConfig config
        (actual ^. includeSection)
          `shouldBe` [ AttributeMatcher "homeConfigurations" "*" Nothing,
                       AttributeMatcher "darwinConfigurations" "foo" Nothing
                     ]
        (actual ^. excludeSection)
          `shouldBe` [AttributeMatcher "nixosConfigurations" "*" Nothing]

      it "parses a missing exclude section to an empty list" $ do
        let config =
              cs
                [i|
                  builds:
                    include: ["*.86_64-linux.*"]
                |]
            actual =
              (^. buildSections . to fromSingleton . excludeSection)
                <$> decodeConfig config
        actual `shouldBe` Right []

      it "parses a missing include section to the default list" $ do
        let config =
              cs
                [i|
                  builds:
                    exclude:
                      - "*.x86_64-linux.*"
                |]
            actual =
              (^. buildSections . to fromSingleton . includeSection)
                <$> decodeConfig config
            defaultInclude =
              (^. buildSections . to fromSingleton . includeSection)
                <$> decodeConfig ""
        actual `shouldBe` defaultInclude

      it "parses configs with multiple 'builds' sections" $ do
        let config =
              cs
                [i|
                  builds:
                    - include:
                        - "packages.*.*"
                      exclude:
                        - "packages.x86_64-linux.*"
                      branch: feature1
                    - include:
                        - "checks.*.*"
                      exclude:
                        - "checks.aarch64-linux.*"
                      branch: feature2
                |]
            actual = (^. buildSections) <$> decodeConfig config
        actual
          `shouldBe` Right
            [ BuildSection
                { _buildSectionIncludeSection = [AttributeMatcher "packages" "*" (Just "*")],
                  _buildSectionExcludeSection = [AttributeMatcher "packages" "x86_64-linux" (Just "*")],
                  _buildSectionBranchSection = Just "feature1"
                },
              BuildSection
                { _buildSectionIncludeSection = [AttributeMatcher "checks" "*" (Just "*")],
                  _buildSectionExcludeSection = [AttributeMatcher "checks" "aarch64-linux" (Just "*")],
                  _buildSectionBranchSection = Just "feature2"
                }
            ]

    describe "incrementalizeBuilds section" $ do
      it "parses the boolean values" $ do
        let config1 =
              cs
                [i|
                  incrementalizeBuilds: true
                |]
        let config2 =
              cs
                [i|
                  incrementalizeBuilds: false
                |]
        let actual1 = (^. incrementalizeBuildsSection) <$> decodeConfig config1
        let actual2 = (^. incrementalizeBuildsSection) <$> decodeConfig config2
        actual1 `shouldBe` Right (IncrementalizeBuilds True)
        actual2 `shouldBe` Right (IncrementalizeBuilds False)

      it "parses the section" $ do
        let config =
              cs
                [i|
                  incrementalizeBuilds:
                    excludeBranches:
                      - main
                |]
        let actual = (^. incrementalizeBuildsSection) <$> decodeConfig config
        actual `shouldBe` Right (IncrementalBuildsExcludeBranches (ExcludeBranches ["main"]))

    describe "server section" $ do
      let roundtripTest :: (Show a, Eq a, HasCodec a) => a -> IO ()
          roundtripTest a = do
            let encoded = encodeJSONViaCodec a
                decoded = eitherDecodeJSONViaCodec encoded
            decoded `shouldBe` Right a

      it "parses an 'on-branch' deployment type of the 'servers' " $ do
        let simpleServerConfig :: ByteString
            simpleServerConfig =
              cs
                $ unindent
                  [i|
                    servers:
                      - configuration: foo
                        deployment:
                          type: on-branch
                          branch: master
                  |]
        let actual = decodeServerSection simpleServerConfig
        actual `shouldBe` Right (ServerSection "foo" (OnBranch (Branch "master") I1x2 False) Nothing False False [] [] [] Nothing Nothing)
        roundtripTest actual

      it "parses and serializes 'on-pull-request' deployment type of the 'servers'" $ do
        let simpleServerConfig :: ByteString
            simpleServerConfig =
              cs
                $ unindent
                  [i|
                    servers:
                      - configuration: foo
                        deployment:
                          type: on-pull-request
                  |]
        let actual = decodeServerSection simpleServerConfig
        actual `shouldBe` Right (ServerSection "foo" (OnPullRequest I1x2) Nothing False False [] [] [] Nothing Nothing)
        roundtripTest actual

      it "parses an 'on-branch' deployment type of the 'servers' with server tier" $ do
        let simpleServerConfig :: ByteString
            simpleServerConfig =
              cs
                $ unindent
                  [i|
                    servers:
                      - configuration: foo
                        deployment:
                          type: on-branch
                          branch: master
                          machine: i4x8
                  |]
        let actual = decodeServerSection simpleServerConfig
        actual `shouldBe` Right (ServerSection "foo" (OnBranch (Branch "master") I4x8 False) Nothing False False [] [] [] Nothing Nothing)
        roundtripTest actual

      it "return a nice error message when failing to parses an 'on-branch' deployment type of the 'servers' with server tier" $ do
        let simpleServerConfig :: ByteString
            simpleServerConfig =
              cs
                $ unindent
                  [i|
                    servers:
                      - configuration: foo
                        deployment:
                          type: on-branch
                          branch: master
                          machine: i4x69
                  |]
        let actual = decodeServerSection simpleServerConfig
        actual `shouldSatisfy` \case
          Left err -> "Wrong server type" `isInfixOf` err
          Right _ -> False

      it "allows setting a primary deployment" $ do
        let simpleServerConfig :: ByteString
            simpleServerConfig =
              cs
                $ unindent
                  [i|
                    servers:
                      - configuration: foo
                        deployment:
                          type: on-branch
                          branch: master
                          isPrimary: true
                  |]
        let actual = decodeServerSection simpleServerConfig
        actual `shouldBe` Right (ServerSection "foo" (OnBranch (Branch "master") I1x2 True) Nothing False False [] [] [] Nothing Nothing)
        roundtripTest actual

      it "accepts a custom absolute application log path" $ do
        let simpleServerConfig :: ByteString
            simpleServerConfig =
              cs
                $ unindent
                  [i|
                    servers:
                      - configuration: foo
                        deployment:
                          type: on-branch
                          branch: master
                        applicationLog:
                          enable: true
                          path: /var/log/my-service.log
                  |]
        let actual = decodeServerSection simpleServerConfig
        actual
          `shouldBe` Right
            (ServerSection "foo" (OnBranch (Branch "master") I1x2 False) Nothing False False [] [] [] (Just (ServerLogFile "/var/log/my-service.log")) Nothing)
        roundtripTest actual

      it "enables the default application log path explicitly" $ do
        let simpleServerConfig :: ByteString
            simpleServerConfig =
              cs
                $ unindent
                  [i|
                    servers:
                      - configuration: foo
                        deployment:
                          type: on-branch
                          branch: master
                        applicationLog:
                          enable: true
                  |]
        let actual =
              (^. logFile)
                <$> decodeServerSection simpleServerConfig
        actual
          `shouldBe` Right
            (Just (ServerLogFile "/var/log/nginx/hello-access.log"))

      it "rejects a relative application log path" $ do
        let simpleServerConfig :: ByteString
            simpleServerConfig =
              cs
                $ unindent
                  [i|
                    servers:
                      - configuration: foo
                        deployment:
                          type: on-branch
                          branch: master
                        applicationLog:
                          enable: true
                          path: var/log/my-service.log
                  |]
        decodeServerSection simpleServerConfig
          `shouldSatisfy` \case
            Left err -> "applicationLog.path must be an absolute path" `isInfixOf` err
            Right _ -> False

    -- Task 3 (nix-native server config, spec §3): the backend discovers
    -- servers from a built nixosConfiguration's
    -- `config.garnix.server.deploySpec` instead of yaml `servers:`.
    -- 'decodeDeploySpec' must decode that JSON aggregate into the exact
    -- same 'ServerSection' the (now-removed) yaml codec would have — this
    -- is the parity guarantee everything downstream (deploy planning,
    -- domains validation, backups capture, exposeSSH, persistence) relies
    -- on to stay unchanged.
    describe "deploySpec decoding (nix-native discovery, §3)" $ do
      it "decodes a real guest-profile.nix deploySpec output to the same ServerSection an equivalent yaml servers: entry produces" $ do
        -- Golden fixture: the real `nix eval --json
        -- .../config.garnix.server.deploySpec` output shape, copied from
        -- 182e616's eval evidence (.agent-skills/sdd/nixnative-t1-report.md,
        -- eval proof (a)) — plus `authentikDefault` (added to
        -- guest-profile.nix in this task's own small follow-up commit;
        -- verified the same way, see this task's report).
        let deploySpecJsonRaw :: String
            deploySpecJsonRaw =
              [i|
                {"applicationLog":null,"authentikDefault":false,"authorizeDeployerGithubKeys":false,"authorizedSSHKeys":[],
                "backups":{"paths":["/var/lib/myapp"],"postBackupCommand":null,"postRestoreCommand":null,
                "preBackupCommand":"echo pre","preRestoreCommand":null,"schedule":"weekly"},
                "deployment":{"branch":"main","isPrimary":true,"machine":"i2x2","type":"on-branch"},
                "domains":["app.example.test","extra.example.test"],"exposeSSH":true,
                "persistence":{"enable":false,"name":null},"ports":[]}
              |]
            Just deploySpecJson = Aeson.decode (cs deploySpecJsonRaw)
            -- The equivalent yaml `servers:` entry — same deployment,
            -- domains, exposeSSH, and backups; nothing else set.
            equivalentYaml :: ByteString
            equivalentYaml =
              cs
                $ unindent
                  [i|
                    servers:
                      - configuration: myapp
                        deployment:
                          type: on-branch
                          branch: main
                          machine: i2x2
                          isPrimary: true
                        domains:
                          - app.example.test
                          - extra.example.test
                        exposeSSH: true
                        backups:
                          paths: [ /var/lib/myapp ]
                          schedule: weekly
                          preBackupCommand: "echo pre"
                  |]
            fromNix = decodeDeploySpec "myapp" deploySpecJson
            fromYaml = decodeServerSection equivalentYaml
        fromNix `shouldBe` (Just <$> fromYaml)

      it "returns Nothing (not a server) when deployment is null" $ do
        let raw :: String
            raw =
              [i|
                    {"applicationLog":null,"authentikDefault":false,"authorizeDeployerGithubKeys":false,
                    "authorizedSSHKeys":[],"backups":null,"deployment":null,"domains":[],"exposeSSH":false,
                    "persistence":{"enable":false,"name":null},"ports":[]}
                  |]
            Just deploySpecJson = Aeson.decode (cs raw)
        decodeDeploySpec "myapp" deploySpecJson `shouldBe` Right Nothing

      it "maps authentikDefault: true to the same authentik: default the yaml codec produces" $ do
        let raw :: String
            raw =
              [i|
                    {"applicationLog":null,"authentikDefault":true,"authorizeDeployerGithubKeys":false,
                    "authorizedSSHKeys":[],"backups":null,
                    "deployment":{"branch":"main","isPrimary":false,"machine":"i1x2","type":"on-branch"},
                    "domains":[],"exposeSSH":false,"persistence":{"enable":false,"name":null},"ports":[]}
                  |]
            Just deploySpecJson = Aeson.decode (cs raw)
        case decodeDeploySpec "myapp" deploySpecJson of
          Right (Just section) -> section ^. authentikSection `shouldBe` Just "default"
          other -> expectationFailure $ cs $ "expected Right (Just ...), got " <> show other

    describe "servers[].backups" $ do
      let roundtripTest :: (Show a, Eq a, HasCodec a) => a -> IO ()
          roundtripTest a = do
            let encoded = encodeJSONViaCodec a
                decoded = eitherDecodeJSONViaCodec encoded
            decoded `shouldBe` Right a

      it "parses a full backups section" $ do
        let config :: ByteString
            config =
              cs
                $ unindent
                  [i|
                    servers:
                      - configuration: fridge
                        deployment:
                          type: on-branch
                          branch: main
                        backups:
                          paths: [ /var/lib/app ]
                          schedule: daily
                          preBackupCommand: "echo pre"
                          preRestoreCommand: "echo pre-restore"
                          postRestoreCommand: "echo post"
                  |]
            actual = decodeServerSection config
            Right (Just section) = (^. backups) <$> decodeServerSection config
        _backupSectionPaths section `shouldBe` ["/var/lib/app"]
        _backupScheduleHours (_backupSectionSchedule section) `shouldBe` 24
        _backupSectionPreBackupCommand section `shouldBe` Just "echo pre"
        _backupSectionPostBackupCommand section `shouldBe` Nothing
        _backupSectionPreRestoreCommand section `shouldBe` Just "echo pre-restore"
        _backupSectionPostRestoreCommand section `shouldBe` Just "echo post"
        roundtripTest actual
        Aeson.decode (Aeson.encode section) `shouldBe` Just section

      it "defaults schedule to daily" $ do
        let config :: ByteString
            config =
              cs
                $ unindent
                  [i|
                    servers:
                      - configuration: fridge
                        deployment:
                          type: on-branch
                          branch: main
                        backups:
                          paths: [ /var/lib/app ]
                  |]
            Right (Just section) = (^. backups) <$> decodeServerSection config
        _backupScheduleHours (_backupSectionSchedule section) `shouldBe` 24

      it "parses interval schedules" $ do
        let hoursFor :: String -> Either String Int
            hoursFor raw = do
              section <-
                decodeServerSection
                  $ cs
                  $ unindent
                    [i|
                      servers:
                        - configuration: fridge
                          deployment:
                            type: on-branch
                            branch: main
                          backups:
                            paths: [ /var/lib/app ]
                            schedule: #{raw}
                    |]
              case section ^. backups of
                Just b -> Right $ _backupScheduleHours (_backupSectionSchedule b)
                Nothing -> Left "expected a backups section"
        hoursFor "6h" `shouldBe` Right 6
        hoursFor "hourly" `shouldBe` Right 1
        hoursFor "weekly" `shouldBe` Right 168

      it "round-trips an interval schedule" $ do
        let config :: ByteString
            config =
              cs
                $ unindent
                  [i|
                    servers:
                      - configuration: fridge
                        deployment:
                          type: on-branch
                          branch: main
                        backups:
                          paths: [ /var/lib/app ]
                          schedule: 6h
                  |]
            actual = decodeServerSection config
            Right (Just section) = (^. backups) <$> decodeServerSection config
        _backupScheduleHours (_backupSectionSchedule section) `shouldBe` 6
        roundtripTest actual

      it "rejects bad schedules" $ do
        let scheduleConfig :: String -> ByteString
            scheduleConfig raw =
              cs
                $ unindent
                  [i|
                    servers:
                      - configuration: fridge
                        deployment:
                          type: on-branch
                          branch: main
                        backups:
                          paths: [ /var/lib/app ]
                          schedule: "#{raw}"
                  |]
            isBadScheduleError = \case
              Left err -> "backups.schedule" `isInfixOf` err
              Right _ -> False
        decodeServerSection (scheduleConfig "0h") `shouldSatisfy` isBadScheduleError
        decodeServerSection (scheduleConfig "sometimes") `shouldSatisfy` isBadScheduleError

      it "rejects bad paths" $ do
        let pathsConfig :: String -> ByteString
            pathsConfig pathsYaml =
              cs
                $ unindent
                  [i|
                    servers:
                      - configuration: fridge
                        deployment:
                          type: on-branch
                          branch: main
                        backups:
                          paths: #{pathsYaml}
                  |]
        decodeServerSection (pathsConfig "[ relative/path ]") `shouldSatisfy` isLeft
        decodeServerSection (pathsConfig "[ / ]") `shouldSatisfy` isLeft
        decodeServerSection (pathsConfig "[ /nix/store/foo ]") `shouldSatisfy` isLeft
        decodeServerSection (pathsConfig "[]") `shouldSatisfy` isLeft

    context "artifacts section" $ do
      it "parses the artifacts section" $ do
        let config =
              cs
                [i|
                  artifacts:
                    - package: web-skills-zips
                      name: claude-skills
                |]
            actual = (^. artifacts) <$> decodeConfig config
        actual
          `shouldBe` Right
            [ ArtifactSection
                { _artifactSectionPackage = "web-skills-zips",
                  _artifactSectionName = Just "claude-skills"
                }
            ]

      it "artifact name defaults to the package" $ do
        artifactDisplayName (ArtifactSection "some-pkg" Nothing) `shouldBe` "some-pkg"

    context "actions section" $ do
      it "allows empty action sections" $ do
        let config = "actions: []"
        decodeConfig config `shouldBe` Right def

      it "parses single action" $ do
        let config =
              cs
                [i|
                  actions:
                    - on: push
                      run: free
                |]
        (_garnixConfigActions <$> decodeConfig config)
          `shouldBe` Right [Action "free" ActionTriggerPush FastStartup False GithubTokenNone]

      it "parses multiple actions" $ do
        let config =
              cs
                [i|
                  actions:
                    - on: push
                      run: free
                      sandboxType: fast-startup
                    - on: push
                      run: wild
                      sandboxType: shared-resources
                      withRepoContents: true
                |]
        (_garnixConfigActions <$> decodeConfig config)
          `shouldBe` Right
            [ Action "free" ActionTriggerPush FastStartup False GithubTokenNone,
              Action "wild" ActionTriggerPush SharedResources True GithubTokenNone
            ]

      it "defaults githubToken to none" $ do
        let config =
              cs
                [i|
                  actions:
                    - on: push
                      run: free
                |]
        (fmap (^. githubToken) . _garnixConfigActions <$> decodeConfig config)
          `shouldBe` Right [GithubTokenNone]

      it "parses the githubToken string modes" $ do
        let config =
              cs
                [i|
                  actions:
                    - on: push
                      run: none-action
                      githubToken: none
                    - on: push
                      run: descoped-action
                      githubToken: descoped
                    - on: push
                      run: repo-action
                      githubToken: repo
                    - on: push
                      run: repo-write-action
                      githubToken: repo-write
                |]
        (fmap (^. githubToken) . _garnixConfigActions <$> decodeConfig config)
          `shouldBe` Right
            [ GithubTokenNone,
              GithubTokenDescoped,
              GithubTokenContents GithubTokenThisRepo GithubTokenRead,
              GithubTokenContents GithubTokenThisRepo GithubTokenWrite
            ]

      it "parses a githubToken list of repositories (contents:read)" $ do
        let config =
              cs
                [i|
                  actions:
                    - on: push
                      run: multi-repo
                      githubToken:
                        - nixpkgs
                        - my-lib
                |]
        (fmap (^. githubToken) . _garnixConfigActions <$> decodeConfig config)
          `shouldBe` Right [GithubTokenContents (GithubTokenNamedRepos ["nixpkgs", "my-lib"]) GithubTokenRead]

      it "parses a githubToken object with explicit repositories and write permission" $ do
        let config =
              cs
                [i|
                  actions:
                    - on: push
                      run: writer
                      githubToken:
                        repositories:
                          - my-lib
                        permission: write
                |]
        (fmap (^. githubToken) . _garnixConfigActions <$> decodeConfig config)
          `shouldBe` Right [GithubTokenContents (GithubTokenNamedRepos ["my-lib"]) GithubTokenWrite]

      it "parses a githubToken object defaulting repositories to this repo" $ do
        let config =
              cs
                [i|
                  actions:
                    - on: push
                      run: writer
                      githubToken:
                        permission: write
                |]
        (fmap (^. githubToken) . _garnixConfigActions <$> decodeConfig config)
          `shouldBe` Right [GithubTokenContents GithubTokenThisRepo GithubTokenWrite]

      it "maps githubToken modes to token scopes" $ do
        githubTokenModeScope GithubTokenNone `shouldBe` Nothing
        githubTokenModeScope GithubTokenDescoped `shouldBe` Just GithubTokenScopeDescoped
        githubTokenModeScope (GithubTokenContents GithubTokenThisRepo GithubTokenRead)
          `shouldBe` Just (GithubTokenScopeContents GithubTokenThisRepo GithubTokenRead)
        githubTokenModeScope (GithubTokenContents (GithubTokenNamedRepos ["a", "b"]) GithubTokenWrite)
          `shouldBe` Just (GithubTokenScopeContents (GithubTokenNamedRepos ["a", "b"]) GithubTokenWrite)

    -- §3 (amended): `servers` is gone from BOTH sources a repo's config can
    -- come from — the yaml file (this test) and a flake's `garnix.config`
    -- output ("rejects a flake garnix.config with a servers key", below).
    -- The "server section" describe block above only exercises
    -- 'decodeServerSection' (a single `servers[0]` entry's own codec, reused
    -- from 'decodeDeploySpec's parity tests) — it never goes through
    -- 'decodeConfig', so it does not actually cover top-level rejection.
    it "rejects a yaml file with a top-level servers key" $ do
      let config :: ByteString
          config =
            cs
              $ unindent
                [i|
                  servers:
                    - configuration: foo
                      deployment:
                        type: on-branch
                        branch: master
                |]
      decodeConfig config
        `shouldBe` Left "servers: moved into nixosConfigurations — declare garnix.server in the configuration (see docs)"

    inM . aroundM_ suppressLogsWhenPassing . context "parsing from flake.nix" $ do
      it "uses default config when there's no yaml file and no config section in flake" $ GH.withFakeGithubInterface $ \ghState -> do
        let emptyFlake =
              cs
                [i|
                  {
                    outputs = _: {};
                  }
                |]
        config <- GH.withLocalRepo ghState "owner" "repo" identity defaultCommitInfo (GH.simpleSetup emptyFlake) $ \commitInfo ->
          runWithCheckout remoteWithConfig commitInfo pure
        config `shouldBeM` def

      -- §3 (amended): `servers` is gone from BOTH sources a repo's config can
      -- come from — the yaml file ("rejects a yaml file with a top-level
      -- servers key", above) and a flake's `garnix.config` output (this
      -- test). garnix.yaml's own hello-server example used exactly this
      -- shape before migrating to `garnix.server` inside the
      -- nixosConfiguration.
      it "rejects a flake garnix.config with a servers key" $ GH.withFakeGithubInterface $ \ghState -> do
        let flake =
              cs
                [i|
                  {
                    outputs = _: {
                      garnix.config = {
                        servers = [
                          {
                            configuration = "foo";
                            deployment = {
                              type = "on-branch";
                              branch = "master";
                            };
                          }
                        ];
                      };
                    };
                  }
                |]
        result <-
          try
            $ GH.withLocalRepo ghState "owner" "repo" identity defaultCommitInfo (GH.simpleSetup flake)
            $ \commitInfo -> runWithCheckout remoteWithConfig commitInfo pure
        case result of
          Left e -> err e `shouldBeM` DecodeConfigError "servers: moved into nixosConfigurations — declare garnix.server in the configuration (see docs)"
          Right (_ :: GarnixConfig) -> liftIO $ expectationFailure "expected a flake garnix.config's servers key to be rejected"

    context "modules section" $ do
      it "sets the publish field for the default section to false" $ do
        let config = ""
        let (Right actual) = decodeConfig config
        actual ^. moduleSection `shouldBe` ModuleSection False

      it "sets the publish field for an empty section to false" $ do
        let config = "modules: {}"
        decodeConfig config `shouldBe` Right def

      it "correctly parses when publish is set to true" $ do
        let config = "modules:\n  publish: true"
        let (Right actual) = decodeConfig config
        actual ^. moduleSection `shouldBe` ModuleSection True

      inM . aroundM_ suppressLogsWhenPassing . context "parsing from flake.nix" $ do
        it "reads module section from garnix.config" $ GH.withFakeGithubInterface $ \ghState -> do
          let flake =
                cs
                  [i|
                    {
                      outputs = _: {
                        garnix.config = {
                          modules = {
                            publish = true;
                          };
                        };
                      };
                    }
                  |]
          config <- GH.withLocalRepo ghState "owner" "repo" identity defaultCommitInfo (GH.simpleSetup flake) $ \commitInfo ->
            runWithCheckout remoteWithConfig commitInfo pure
          (config ^. moduleSection) `shouldBeM` ModuleSection True

    describe "fodChecks section" $ do
      it "allows enabling FOD checks" $ do
        let config =
              cs
                [i|
                  fodChecks: true
                |]
        let actual = (^. fodChecks) <$> decodeConfig config
        actual `shouldBe` Right True

    describe "autoCancelSuperseded section" $ do
      it "defaults to false" $ do
        let actual = (^. autoCancelSuperseded) <$> decodeConfig ""
        actual `shouldBe` Right False

      it "parses an explicit true" $ do
        let config =
              cs
                [i|
                  autoCancelSuperseded: true
                |]
        let actual = (^. autoCancelSuperseded) <$> decodeConfig config
        actual `shouldBe` Right True

      it "still parses a config carrying the removed legacy cancelSupersededBuilds key, ignoring it (unknown-key, autodocodec object decode) and leaving the flag false" $ do
        let config =
              cs
                [i|
                  cancelSupersededBuilds: true
                |]
        let actual = (^. autoCancelSuperseded) <$> decodeConfig config
        actual `shouldBe` Right False
