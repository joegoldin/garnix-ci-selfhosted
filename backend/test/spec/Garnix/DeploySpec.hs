module Garnix.DeploySpec (spec) where

import Autodocodec (toJSONViaCodec)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)
import Control.Lens
import Cradle
import Data.Aeson qualified as Aeson
import Data.Map ((!))
import Data.Map qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.String.Interpolate
import Data.Text qualified as Text
import Data.Text.IO qualified as T
import Data.Tuple.Extra ((&&&))
import Database.PostgreSQL.Typed (pgSQL)
import Garnix.API.GhWebhooks (ghWebhookPullRequest)
import Garnix.Async (timeout)
import Garnix.Backups (BackupTarget (..), runServerBackup, runServerRestore)
import Garnix.Build (buildFlake)
import Garnix.Build.Checkout qualified as Build.Checkout
import Garnix.Build.Helpers (withPrivateNixXdgCache)
import Garnix.DB qualified as DB
import Garnix.DB.Backups qualified as Backups
import Garnix.Duration (fromSeconds)
import Garnix.Hosting.Deploy
import Garnix.Hosting.ServerPool (sshArgsFor)
import Garnix.Monad
import Garnix.Monad.Async (emptyPromise, resolve)
import Garnix.Monad.SubProcess (runSubProcess_)
import Garnix.Orchestrator qualified as Orchestrator
import Garnix.Prelude hiding (head)
import Garnix.TestHelpers hiding (shouldReturn)
import Garnix.TestHelpers.Common
import Garnix.TestHelpers.Deprecated qualified as Deprecated
import Garnix.TestHelpers.Monad
import Garnix.TestHelpers.ProvisionerMock (Thread (..), provisionerMockState, _getProvisionerState)
import Garnix.TestHelpers.Reporter (withTestReporter_)
import Garnix.TestHelpers.ServerPool
import Garnix.Types hiding (context)
import Garnix.YamlConfig (BackupSchedule (..), BackupSection (..), DeploySection (OnBranch, OnPullRequest), GarnixConfig, ServerLogFile (..), ServerPort (..), ServerPortType (..), ServerSection (..))
import GitHub.Data.Id qualified as Github.Data
import GitHub.Data.Webhooks.Events (CheckSuiteEvent (..), EventHasRepo (..), PullRequestEvent, senderOfEvent)
import GitHub.Data.Webhooks.Payload (HookCheckSuite (..), HookRepository (..), whUserLogin)
import System.IO.Temp (withSystemTempDirectory)
import Test.HUnit (assertFailure)
import Test.Hspec hiding (shouldThrow)

spec :: Spec
spec = do
  describe "rolloutNewServerVersion @slow"
    $ before truncateDB
    $ after_ stopActiveServers
    $ around_ Deprecated.quietWhenPassing
    $ aroundAll_ withServerPool
    $ do
      it "deploys a new server" $ do
        let event = defaultEvent
        runTestM $ withContext event $ \repoInfo branch -> do
          commitInfo <- doABuild simpleFlake event repoInfo
          withMatchingConfig branch (PackageName "default") $ do
            servers <- rolloutNewServerVersion mempty commitInfo (BranchDeployment branch)
            liftIO $ length servers `shouldBe` 1
            forM_ servers $ \server -> server `shouldHaveState` "running"
            case servers ^.. traversed . readyAt of
              res | any isNothing res -> liftIO $ assertFailure "expected ready flag to be set in returned serverInfo"
              _ -> pure ()

      it "does not deploy on any failing builds" $ do
        let event = defaultEvent
        runTestM $ withContext event $ \repoInfo branch -> do
          withMatchingConfig branch (PackageName "myHost") $ do
            _ <- doABuild flakeWithFailingBuilds event repoInfo
            serverLogs <- getDeployLogsDB
            liftIO $ serverLogs `shouldBe` []

      it "does nothing if the branch doesn't match" $ do
        let event = defaultEvent
        runTestM $ withContext event $ \repoInfo branch -> do
          commitInfo <- doABuild simpleFlake event repoInfo
          withMatchingConfig "something-else" (PackageName "default") $ do
            servers <- rolloutNewServerVersion mempty commitInfo (BranchDeployment branch)
            liftIO $ length servers `shouldBe` 0

      it "does nothing if there are no servers to deploy" $ do
        let event = defaultEvent
        runTestM $ withContext event $ \repoInfo branch -> do
          commitInfo <- doABuild simpleFlake event repoInfo
          withUnmatchingConfig $ do
            servers <- rolloutNewServerVersion mempty commitInfo (BranchDeployment branch)
            liftIO $ length servers `shouldBe` 0

      it "deletes old servers" $ do
        let event = defaultEvent
        runTestM $ withContext event $ \repoInfo branch -> do
          commitInfo <- doABuild simpleFlake event repoInfo
          withMatchingConfig branch (PackageName "default") $ do
            firstGenServers <- rolloutNewServerVersion mempty commitInfo (BranchDeployment branch)
            void $ rolloutNewServerVersion mempty commitInfo (BranchDeployment branch)
            forM_ firstGenServers assertNotExists

      context "persistence" $ do
        -- The mock flakes declare github: inputs, so the RepoInfo needs the
        -- (mocked) installation auth — with Nothing, buildFlake dies in
        -- authorizeGithubPrivateInputs with "missing GitHub installation auth".
        let mkCommitInfo c = do
              iAuth <- getInstallation $ Github.Data.Id 42
              pure $ CommitInfo "owner" (RepoIsPublic True) (RepoInfo ForgeGithub (Just iAuth) (GhToken "test-token") "owner" "repo") (Just "branch") Nothing c
            flake = flakeWithPersistence True "db" "db" "local"
            -- No `servers:` yaml at all now (§3, removed from the schema
            -- entirely) — deployment/persistence are mocked directly at the
            -- 'discoverDeploySpecMock' seam below, standing in for BOTH the
            -- real `nix eval` Garnix.Build.Package would have done
            -- (persistence capture) and the one Garnix.Hosting.Deploy would
            -- have done (deploy planning) — see 'withServerSectionAndPersistence'.
            yaml = Nothing
            branch = "branch"
        context "build" $ around_ Deprecated.addTestSecrets $ do
          it "fails if persistence is enabled with an empty name" $ do
            (Left error) <- Deprecated.withMockRepo (cs flake) yaml branch $ \_mockGithubRepo commit -> do
              withServerSectionAndPersistence "db" (onBranchSection "db" branch) (Just "")
                $ withMockReturning #executeDeployPlanMock []
                $ do
                  resolve =<< buildFlake mempty =<< mkCommitInfo commit
            err error `shouldBe` NameIsNotValidSubdomain PersistenceNameSubdomain ""

        context "planning" $ around_ Deprecated.addTestSecrets $ do
          it "ignores persistence names if persistence is not enabled" $ do
            result <- Deprecated.withMockRepo (cs flake) yaml branch $ \_mockGithubRepo commit -> do
              withServerSectionAndPersistence "db" (onBranchSection "db" branch) Nothing
                $ withMockReturning #executeDeployPlanMock []
                $ do
                  resolve =<< buildFlake mempty =<< mkCommitInfo commit
                  (_, _, plan1, _) <- fromSingleton <$> getMockCalls #executeDeployPlanMock
                  liftIO $ plan1 ^.. #toSpinUp . traverse . #build . persistenceName `shouldBe` [Nothing]
            result `shouldBe` Right ()

          it "fails if persistence name is not a valid subdomain" $ do
            (Left error) <- Deprecated.withMockRepo (cs flake) yaml branch $ \_mockGithubRepo commit -> do
              withServerSectionAndPersistence "db" (onBranchSection "db" branch) (Just "db/invalid-name")
                $ withMockReturning #executeDeployPlanMock []
                $ do
                  resolve =<< buildFlake mempty =<< mkCommitInfo commit
            err error `shouldBe` NameIsNotValidSubdomain PersistenceNameSubdomain "db/invalid-name"

          it "correctly reads and stores the persistence name" $ do
            result <- Deprecated.withMockRepo (cs flake) yaml branch $ \_mockGithubRepo commit -> do
              withServerSectionAndPersistence "db" (onBranchSection "db" branch) (Just "db")
                $ withMockReturning #executeDeployPlanMock []
                $ do
                  resolve =<< buildFlake mempty =<< mkCommitInfo commit
                  (_, _, plan1, _) <- fromSingleton <$> getMockCalls #executeDeployPlanMock
                  liftIO $ plan1 ^.. #toSpinUp . traverse . #build . persistenceName `shouldBe` [Just "db"]
            result `shouldBe` Right ()

          it "plans to redeploy to the same server" $ do
            result <- Deprecated.withMockRepo (cs flake) yaml branch $ \_mockGithubRepo commit -> do
              withServerSectionAndPersistence "db" (onBranchSection "db" branch) (Just "db")
                $ withMockReturning #executeDeployPlanMock []
                $ do
                  now <- liftIO getCurrentTime
                  [existingBuild] <- createBuildsFor "owner" "repo" "branch" "prevcommit" [("db", Just "db")]
                  void $ addTestServer $ \server ->
                    server
                      & configurationBuildId .~ (existingBuild ^. id)
                      & readyAt ?~ now
                      & endedAt .~ Nothing

                  resolve =<< buildFlake mempty =<< mkCommitInfo commit

                  (_, _, plan1, _) <- fromSingleton <$> getMockCalls #executeDeployPlanMock

                  liftIO $ length (plan1 ^. #toSpinUp) `shouldBe` 0
                  liftIO $ length (plan1 ^. #toSpinDown) `shouldBe` 0
                  liftIO $ length (plan1 ^. #toRedeploy) `shouldBe` 1
            result `shouldBe` Right ()

          it "keeps runtime configuration in a persistent redeploy plan" $ do
            let runtimeSection =
                  ServerSection
                    "db"
                    (OnBranch branch def False)
                    (Just "default")
                    True -- exposeSSH
                    True -- authorizeDeployerGithubKeys
                    ["ssh-ed25519 AAAATEST explicit@test"]
                    [ ServerPort 8080 "web" HttpPort,
                      ServerPort 5432 "database" TcpPort
                    ]
                    ["db.example.test"]
                    (Just (ServerLogFile "/var/log/database.log"))
                    Nothing
            result <- Deprecated.withMockRepo (cs flake) yaml branch $ \_mockGithubRepo commit -> do
              withServerSectionAndPersistence "db" runtimeSection (Just "db")
                $ withMockReturning #executeDeployPlanMock []
                $ do
                  now <- liftIO getCurrentTime
                  [existingBuild] <- createBuildsFor "owner" "repo" "branch" "prevcommit" [("db", Just "db")]
                  existingServer <- addTestServer $ \server ->
                    server
                      & configurationBuildId .~ (existingBuild ^. id)
                      & readyAt ?~ now
                      & endedAt .~ Nothing
                  DB.setServerDomains (existingServer ^. id) ["db.example.test"]

                  resolve =<< buildFlake mempty =<< mkCommitInfo commit

                  (_, _, plan1, _) <- fromSingleton <$> getMockCalls #executeDeployPlanMock
                  let [(_, wanted)] = plan1 ^. #toRedeploy
                  liftIO $ do
                    wanted ^. #useDefaultAuthentik `shouldBe` True
                    wanted ^. #exposeSSH `shouldBe` True
                    wanted ^. #authorizeDeployerGithubKeys `shouldBe` True
                    wanted ^. #authorizedSSHKeys `shouldBe` ["ssh-ed25519 AAAATEST explicit@test"]
                    wanted ^. #httpPorts `shouldBe` [("web", 8080)]
                    wanted ^. #tcpPorts `shouldBe` [("database", 5432)]
                    wanted ^. #domains `shouldBe` ["db.example.test"]
                    wanted ^. #logFile `shouldBe` Just "/var/log/database.log"
            result `shouldBe` Right ()

      it "does not mark server as ready from a failed deployment" $ do
        let event = defaultEvent
        let packages = [PackageName "first", PackageName "second"]
        let sort' = sortOn (getHashId . getServerId . _serverInfoId)
        runTestM $ withContext event $ \repoInfo branch -> do
          commitInfo <- doABuild (makeMultiFlake packages) event repoInfo
          withMultiConfig branch packages $ do
            void $ rolloutNewServerVersion mempty commitInfo (BranchDeployment branch)
            firstGenServers <- sort' <$> getAllDbServers
            liftIO $ length firstGenServers `shouldBe` 2

            sync <- liftIO newEmptyMVar
            void
              $ try
              $ withMock #startServerMock (startServerAndFailOnAllExcept sync "first")
              $ rolloutNewServerVersion mempty commitInfo (BranchDeployment branch)
            secondGenServers <- (\\ firstGenServers) . sort' <$> getAllDbServers

            liftIO $ fmap (^. endedAt) firstGenServers `shouldBe` [Nothing, Nothing]
            liftIO $ length secondGenServers `shouldBe` 1
            liftIO $ fmap (^. readyAt) secondGenServers `shouldBe` [Nothing]

      it "deletes servers from previous deploys that did not successfully initialize" $ do
        let event = defaultEvent
        runTestM $ withContext event $ \repoInfo branch -> do
          commitInfo <- doABuild simpleFlake event repoInfo
          withMatchingConfig branch (PackageName "default") $ do
            firstGenServers <- rolloutNewServerVersion mempty commitInfo (BranchDeployment branch)
            liftIO $ length firstGenServers `shouldBe` 1
            -- Simulate a previous deploy that never initialized: clear the
            -- readiness the pool set. (Servers now provision on demand, so the
            -- old waitTillServerIsInitializedMock=False no longer models this —
            -- it just makes provisionOne throw.) getRunningServersOf filters on
            -- ended_at only, so deploy-2 still picks this up and must reap it.
            void $ DB.pgExec [pgSQL| UPDATE servers SET ready_at = NULL |]
            void $ rolloutNewServerVersion mempty commitInfo (BranchDeployment branch)
            forM_ firstGenServers $ \server ->
              assertNotExists server

      it "does not delete servers from a different branch" $ do
        let event = defaultEvent
        runTestM $ withContext event $ \repoInfo branch -> do
          commitInfo1 <- doABuild simpleFlake event repoInfo
          withMatchingConfig branch (PackageName "default") $ do
            firstGenServers <- rolloutNewServerVersion mempty commitInfo1 (BranchDeployment branch)
            liftIO $ length firstGenServers `shouldBe` 1
            let event2 = defaultEvent & eventBranch ?~ "some-other-branch"
            withContext event2 $ \repoInfo branch -> do
              commitInfo2 <- doABuild (simpleFlake' "Some other description") event2 repoInfo
              withMatchingConfig branch (PackageName "default") $ do
                secondGenServers <- rolloutNewServerVersion mempty commitInfo2 (BranchDeployment branch)
                liftIO $ length secondGenServers `shouldBe` 1
                forM_ firstGenServers $ \server ->
                  server `shouldHaveState` "running"

      it "deploys the repo key to /var/garnix/keys/repo-key (only root readable)" $ do
        let event = defaultEvent
        runTestM $ withContext event $ \repoInfo branch -> do
          commitInfo <- doABuild simpleFlake event repoInfo
          withMatchingConfig branch (PackageName "default") $ do
            [server] <- rolloutNewServerVersion mempty commitInfo (BranchDeployment branch)
            (ip, sshArgs) <- sshArgsFor server
            StdoutRaw result <-
              run $ cmd "ssh"
                & addArgs
                  (sshArgs <> ["root@" <> cs ip, "cat /var/garnix/keys/repo-key"])

            liftIO $ cs result `shouldStartWith` "AGE-SECRET-KEY"

      it "deploys the terminal CA public key to the durable guest path" $ do
        let event = defaultEvent
        runTestM $ withContext event $ \repoInfo branch -> do
          commitInfo <- doABuild simpleFlake event repoInfo
          withMatchingConfig branch (PackageName "default") $ do
            [server] <- rolloutNewServerVersion mempty commitInfo (BranchDeployment branch)
            terminalCaKey <- view #sshTerminalCaKey
            expected <-
              liftIO (deriveSshPublicKey terminalCaKey)
                >>= either (error . cs) pure
            (ip, sshArgs) <- sshArgsFor server
            StdoutRaw actual <-
              run $ cmd "ssh"
                & addArgs
                  (sshArgs <> ["root@" <> cs ip, "cat /var/lib/garnix/terminal-ca.pub"])

            liftIO $ Text.strip (cs actual) `shouldBe` expected

      context "stopUnusedServers" $ do
        let mkCommitInfo c = do
              iAuth <- getInstallation $ Github.Data.Id 42
              pure $ CommitInfo "owner" (RepoIsPublic True) (RepoInfo ForgeGithub (Just iAuth) (GhToken "test-token") "owner" "repo") (Just "branch") Nothing c
            flake = flakeWithPersistence True "db" "db" "local"
            yaml = Nothing
            branch = "branch"
            runPrEvent ci = withServerSection "db" (onPullRequestSection "db") $ do
              resolve =<< buildFlake mempty ci
              void $ Build.Checkout.withCheckout ci $ rolloutNewServerVersion mempty ci (GhPrDeployment 1)

        it "stops servers that do not have a heartbeat" $ Deprecated.addTestSecrets $ do
          result <- Deprecated.withMockRepo flake yaml branch $ \_mockGithubRepo commit -> do
            ci <- mkCommitInfo commit

            runPrEvent ci
            before <- fromSingleton <$> getAllDbServers
            void
              $ DB.pgExec
                [pgSQL|
                  UPDATE servers
                    SET ready_at = (ready_at - interval '13 hours')
                |]
            stopUnusedServers
            after <- fromSingleton <$> getAllDbServers

            liftIO $ do
              before ^. endedAt `shouldBe` Nothing
              after ^. endedAt `shouldNotBe` Nothing
              before ^. id `shouldBe` after ^. id

          result `shouldBe` Right ()

        it "does not stop servers were started recently" $ Deprecated.addTestSecrets $ do
          result <- Deprecated.withMockRepo flake yaml branch $ \_mockGithubRepo commit -> do
            ci <- mkCommitInfo commit

            runPrEvent ci
            before <- fromSingleton <$> getAllDbServers
            stopUnusedServers
            after <- fromSingleton <$> getAllDbServers

            liftIO $ do
              before ^. endedAt `shouldBe` Nothing
              after ^. endedAt `shouldBe` Nothing
              before ^. id `shouldBe` after ^. id

          result `shouldBe` Right ()

        it "does not stop servers with a heartbeat" $ Deprecated.addTestSecrets $ do
          result <- Deprecated.withMockRepo flake yaml branch $ \_mockGithubRepo commit -> do
            ci <- mkCommitInfo commit

            runPrEvent ci
            before <- fromSingleton <$> getAllDbServers
            void
              $ DB.pgExec
                [pgSQL|
                  UPDATE servers
                    SET ready_at = (ready_at - interval '13 hours')
                    WHERE servers.id = ${before ^. id}
                |]
            hosts <- DB.getAllRunningHosts
            void $ DB.upsertHeartbeat $ fmap hostToDomainName hosts
            stopUnusedServers
            after <- fromSingleton <$> getAllDbServers

            liftIO $ do
              before ^. endedAt `shouldBe` Nothing
              after ^. endedAt `shouldNotBe` Nothing
              before ^. id `shouldBe` after ^. id

          result `shouldBe` Right ()

        it "does not stop branch servers" $ Deprecated.addTestSecrets $ do
          result <- Deprecated.withMockRepo flake Nothing branch $ \_mockGithubRepo commit -> do
            ci <- mkCommitInfo commit

            withServerSection "db" (onBranchSection "db" branch) $ do
              resolve =<< buildFlake mempty ci
              before <- fromSingleton <$> getAllDbServers
              void
                $ DB.pgExec
                  [pgSQL|
                    UPDATE servers
                      SET ready_at = (ready_at - interval '13 hours')
                      WHERE servers.id = ${before ^. id}
                  |]
              stopUnusedServers
              after <- fromSingleton <$> getAllDbServers

              liftIO $ do
                before ^. endedAt `shouldBe` Nothing
                after ^. endedAt `shouldBe` Nothing
                before ^. id `shouldBe` after ^. id

          result `shouldBe` Right ()

      describe "deployment reporting" $ do
        it "stores deploy logs of failing deployments" $ do
          let event = defaultEvent
          runTestM $ withContext event $ \repoInfo branch -> do
            withMock #setupServerMock (\_ -> throw $ ProvisioningError "test error") $ do
              commitInfo <- doABuild simpleFlake event repoInfo
              withMatchingConfig branch (PackageName "default") $ do
                Left result <- try $ rolloutNewServerVersion mempty commitInfo (BranchDeployment branch)
                liftIO $ err result `shouldBe` ProvisioningError "test error"
                [(_id, deployLogs)] <- getDeployLogsDB
                liftIO $ deployLogs `shouldBe` "Error provisioning server: test error\n"
                [failedServer] <- getAllDbServers
                liftIO $ failedServer ^. endedAt `shouldSatisfy` isJust

        it "reports failed deployments to github" $ do
          let event = defaultEvent
          runTestM $ withContext event $ \repoInfo branch -> do
            withMock #setupServerMock (\_ -> throw $ ProvisioningError "test error") $ do
              commitInfo <- doABuild simpleFlake event repoInfo
              withMatchingConfig branch (PackageName "default") $ do
                result <- withTestReporter_ $ \reporter ->
                  void $ try $ rolloutNewServerVersion reporter commitInfo (BranchDeployment branch)
                let (Just testReport) = result ^? ix "deployment default"
                (testReport ^. #success) `shouldBeM` Just False
                -- `shouldContain`, not `shouldStartWith`: the deploy report now
                -- opens with the live provisioning-progress lines ("Provisioning …
                -- on a … guest", "Guest … ready — activating configuration…") that
                -- the WAITING-ON tree shows, so the failure message no longer leads.
                liftIO $ testReport ^. #logs . to cs `shouldContain` "Error provisioning server: test error"

        it "reports failed activations to github" $ do
          let event = defaultEvent
              testServerInfo =
                ServerInfo
                  { _serverInfoId = ServerId $ 1 ^. from hashIdInt,
                    _serverInfoProvisionedServerId = ProvisionedServerId 20950838,
                    _serverInfoIpv4Addr = "<none>",
                    _serverInfoIpv6Addr = "<none>",
                    _serverInfoCreatedAt = error "not used",
                    _serverInfoEndedAt = Nothing,
                    _serverInfoConfigurationBuildId = BuildId $ 123 ^. from hashIdInt,
                    _serverInfoPullRequest = Nothing,
                    _serverInfoReadyAt = Nothing,
                    _serverInfoBuildPersistenceName = Nothing,
                    _serverInfoTier = def,
                    _serverInfoIsPrimary = False
                  }
              expectedError =
                ActivationError
                  ( testServerInfo
                      & ipv4Addr
                        .~ "12.34.56.78"
                      & ipv6Addr
                        .~ "0123:4567:89ab:cdef::/64"
                  )
                  "some stderr"
          runTestM $ withContext event $ \repoInfo branch -> do
            withMock #setupServerMock (\_ -> throw expectedError) $ do
              commitInfo <- doABuild simpleFlake event repoInfo
              withMatchingConfig branch (PackageName "default") $ do
                result <- withTestReporter_ $ \reporter -> do
                  void $ try $ rolloutNewServerVersion reporter commitInfo (BranchDeployment branch)
                let (Just testReport) = result ^? ix "deployment default"
                (testReport ^. #success) `shouldBeM` Just False
                -- `shouldContain`, not `shouldStartWith`: the report now opens with
                -- the live provisioning-progress prefix before the activation error.
                liftIO $ testReport ^. #logs . to cs `shouldContain` "Failed to activate server\nYou may be able to debug this by sshing into 12.34.56.78 or 0123:4567:89ab:cdef::/64\nStderr:\nsome stderr\n"

        it "reports successful deployments to github" $ do
          let event = defaultEvent
          runTestM $ withContext event $ \repoInfo branch -> do
            commitInfo <- doABuild simpleFlake event repoInfo
            withMatchingConfig branch (PackageName "default") $ do
              reports <- withTestReporter_ $ \reporter ->
                void $ try $ rolloutNewServerVersion reporter commitInfo (BranchDeployment branch)
              let logs' = cs $ (reports ! "deployment default") ^. #logs
              liftIO $ do
                logs' `shouldContain` "Server has been successfully deployed to: https://default.branch.repo.owner.garnix.me"
                logs' `shouldContain` "starting the following units:"

        it "includes activate script output on failures" $ do
          let event = defaultEvent
          runTestM $ withContext event $ \repoInfo branch -> do
            commitInfo <- doABuild flakeWithFailingActivation event repoInfo
            withMatchingConfig branch (PackageName "default") $ do
              reports <- withTestReporter_ $ \reporter -> do
                void $ try $ rolloutNewServerVersion reporter commitInfo (BranchDeployment branch)
              let logs' = cs $ (reports Map.! "deployment default") ^. #logs
              liftIO $ do
                logs' `shouldContain` "Failed to activate server"
                logs' `shouldContain` "activationFailure: command not found"

  -- These scenarios perform multiple real guest activations against one
  -- persistent VM. Give each its own pool instead of the randomized describe's
  -- shared pool: teardown and asynchronous pool replenishment from a previous
  -- example can otherwise overlap activation and make the tests order-dependent.
  describe "persistent server reuse @slow"
    $ before truncateDB
    $ after_ stopActiveServers
    $ around_ Deprecated.quietWhenPassing
    $ aroundAll_ withServerPool
    $ it "reuses a server"
    $ Deprecated.addTestSecrets
    $ do
      let mkCommitInfo c = do
            iAuth <- getInstallation $ Github.Data.Id 42
            pure $ CommitInfo "owner" (RepoIsPublic True) (RepoInfo ForgeGithub (Just iAuth) (GhToken "test-token") "owner" "repo") (Just "branch") Nothing c
          flake = flakeWithPersistence True "db" "db" "local"
          yaml = Nothing
          branch = "branch"
          sshServer serverInfo args = do
            (ip, sshArgs) <- sshArgsFor serverInfo
            StdoutRaw stdout <- run $ cmd "ssh" & addArgs (sshArgs <> (("garnix@" <> ip) : args))
            pure stdout
      result <- Deprecated.withMockRepo flake yaml branch $ \mockGithubRepo commit -> do
        withServerSectionAndPersistence "db" (onBranchSection "db" branch) (Just "db") $ do
          resolve =<< buildFlake mempty =<< mkCommitInfo commit
          firstGenServer <- fromSingleton <$> getAllDbServers

          terminalCaKey <- view #sshTerminalCaKey
          expectedTerminalCa <-
            liftIO (deriveSshPublicKey terminalCaKey)
              >>= either (error . cs) pure

          void $ sshServer firstGenServer ["sudo", "touch", "/hello"]
          void
            $ sshServer
              firstGenServer
              ["sudo", "truncate", "-s", "0", "/var/lib/garnix/terminal-ca.pub"]

          liftIO $ writeFile (mockGithubRepo </> "flake.nix") (cs $ flakeWithPersistence True "db" "db" "second")
          commit2 <- commitAll mockGithubRepo
          resolve =<< buildFlake mempty =<< mkCommitInfo commit2
          secondGenServers <- getAllDbServers

          liftIO $ length secondGenServers `shouldBe` 1
          let secondGen = fromSingleton secondGenServers

          stdout <- sshServer secondGen ["sudo", "ls", "/hello"]
          terminalCa <- sshServer secondGen ["cat", "/var/lib/garnix/terminal-ca.pub"]

          liftIO $ do
            firstGenServer ^. configurationBuildId `shouldNotBe` secondGen ^. configurationBuildId
            firstGenServer ^. id `shouldBe` secondGen ^. id
            firstGenServer ^. ipv4Addr `shouldBe` secondGen ^. ipv4Addr
            stdout `shouldBe` "/hello\n"
            Text.strip (cs terminalCa) `shouldBe` expectedTerminalCa

      result `shouldBe` Right ()

  -- Lives here rather than in Garnix.Backups.SchedulerSpec because the real-guest
  -- fixture (withServerPool + withMockRepo + buildFlake) is defined in this module
  -- and not exported; the scheduler spec covers the pure and DB-only paths.
  describe "server backup round-trip @slow"
    $ before truncateDB
    $ after_ stopActiveServers
    $ around_ Deprecated.quietWhenPassing
    $ aroundAll_ withServerPool
    $ it "captures a guest's paths, uploads, and restores them"
    $ Deprecated.addTestSecrets
    $ do
      let mkCommitInfo c = do
            iAuth <- getInstallation $ Github.Data.Id 42
            pure $ CommitInfo "owner" (RepoIsPublic True) (RepoInfo ForgeGithub (Just iAuth) (GhToken "test-token") "owner" "repo") (Just "branch") Nothing c
          -- flakeWithPersistence (not simpleFlake): its guest authorizes the
          -- garnix user, which is the identity the backup pipeline SSHes as.
          flake = flakeWithPersistence True "db" "db" "local"
          yaml = Nothing
          branch = "branch"
          -- One argv element, so the guest's shell parses the redirect rather
          -- than the local one.
          sshServer serverInfo remoteCommand = do
            (ip, sshArgs) <- sshArgsFor serverInfo
            StdoutRaw stdout <- run $ cmd "ssh" & addArgs (sshArgs <> ["garnix@" <> ip, remoteCommand])
            pure (cs stdout :: Text)
          section =
            BackupSection
              { _backupSectionPaths = ["/var/lib/testdata"],
                _backupSectionSchedule = BackupSchedule "daily" 24,
                _backupSectionPreBackupCommand = Just "touch /var/lib/testdata/pre-ran",
                _backupSectionPostBackupCommand = Nothing,
                _backupSectionPreRestoreCommand = Nothing,
                _backupSectionPostRestoreCommand = Nothing
              }
      result <- Deprecated.withMockRepo flake yaml branch $ \_mockGithubRepo commit -> withServerSectionAndPersistence "db" (onBranchSection "db" branch) (Just "db") $ do
        resolve =<< buildFlake mempty =<< mkCommitInfo commit
        server <- fromSingleton <$> getAllDbServers
        void
          $ sshServer server "sudo mkdir -p /var/lib/testdata && sudo sh -c 'echo hello-backup > /var/lib/testdata/hello.txt'"
        Backups.setServerBackups (server ^. id) (Just section)

        withSystemTempDirectory "garnix-backup-store" $ \storeDir -> do
          let target =
                BackupTarget
                  { _backupTargetServerId = server ^. id,
                    _backupTargetIpv4 = server ^. ipv4Addr,
                    _backupTargetRepoUser = "owner",
                    _backupTargetRepoName = "repo",
                    _backupTargetBranch = Just "branch",
                    _backupTargetConfiguration = "db",
                    _backupTargetPersistenceName = Just "db",
                    _backupTargetSection = section
                  }
              -- A local-directory BackupStore: keys are flattened into filenames.
              objectPath key = storeDir </> cs (Text.replace "/" "_" key)
              store =
                BackupStore
                  { _backupStorePutFile = \key path ->
                      runSubProcess_ $ cmd "cp" & addArgs [cs path, cs (objectPath key) :: Text],
                    _backupStoreGetFile = \key path ->
                      runSubProcess_ $ cmd "cp" & addArgs [cs (objectPath key), cs path :: Text],
                    _backupStoreDeleteObject = \_ -> pure (),
                    _backupStorePresignGet = pure,
                    _backupStoreMaxSize = 4294967296
                  }

          runServerBackup store target "manual"

          rows <- Backups.getBackupsForRepo "owner" "repo"
          row <- case rows of
            [row] -> pure row
            _ -> liftIO $ assertFailure "expected exactly one backup row"
          liftIO $ Backups._backupRowStatus row `shouldBe` "success"
          objectHash <- case Backups._backupRowObjectHash row of
            Just h -> pure h
            Nothing -> liftIO $ assertFailure "successful backup should record an object hash"
          Backups.backupObjectExists objectHash >>= \exists ->
            liftIO $ exists `shouldBe` True
          -- The pre-backup hook ran on the guest, inside the captured path.
          preRan <- sshServer server "ls /var/lib/testdata/pre-ran"
          liftIO $ Text.strip preRan `shouldBe` "/var/lib/testdata/pre-ran"

          -- Destroy the data, then restore it from the snapshot.
          void $ sshServer server "sudo rm -rf /var/lib/testdata"
          runServerRestore store row server "test-user"
          restored <- sshServer server "cat /var/lib/testdata/hello.txt"
          liftIO $ Text.strip restored `shouldBe` "hello-backup"

      result `shouldBe` Right ()

  describe "persistent redeployment reporting @slow"
    $ before truncateDB
    $ after_ stopActiveServers
    $ around_ Deprecated.quietWhenPassing
    $ aroundAll_ withServerPool
    $ it "reports redeployment of a persistent server"
    $ do
      let event = defaultEvent
      runTestM $ withContext event $ \repoInfo branch -> withServerSectionAndPersistence "db" (onBranchSection "db" branch) (Just "db") $ do
        let flake = flakeWithPersistence True "db" "db" "local"
        _ <- doABuild flake event repoInfo
        let flake2 = flakeWithPersistence True "db" "db" "local2"
        commitInfo <- doABuild flake2 event repoInfo
        let builds = DB.getBuildsByCommit (repoInfo ^. ghRepoOwner) (repoInfo ^. ghRepoName) (commitInfo ^. commit)
        build <- fromSingleton . filter (\p -> p ^. packageType == TypeNixosConfiguration) <$> builds
        secondGenServers <- getAllDbServers
        let serverInfo2 = fromSingleton secondGenServers
            wanted = ServerToSpinUp def build False False False False [] [] [] [] Nothing Nothing
        reports <- withTestReporter_ $ \reporter -> do
          void $ redeployServer reporter commitInfo (BranchDeployment branch) serverInfo2 wanted
        let logs' = cs $ (reports Map.! "redeployment db") ^. #logs
        liftIO $ do
          logs' `shouldContain` "Server has been successfully redeployed to: https://db.branch.repo.owner.garnix.me"

  describe "branch deployments" $ inM $ beforeM_ truncateDBM $ do
    let user = "owner"
        name = "repo"
        commit = "aaaa"
        branchName = "branch"
    it "allows deploying 0 servers"
      $ withMockReturning #executeDeployPlanMock []
      $ do
        result <- try $ deployNewServerFor "owner" "repo" "branch" "aaaaaa" []
        liftIO $ result `shouldBe` Right []

    it "allows deploying 1 server"
      $ withMockReturning #executeDeployPlanMock []
      $ do
        let machineName = "test-machine"
        void $ deployNewServerFor user name branchName commit [(machineName, Nothing)]
        (_, _, plan, _) <- fromSingleton <$> getMockCalls #executeDeployPlanMock
        liftIO $ length (plan ^. #toSpinUp) `shouldBe` 1

    it "allows specifying a primary domain deployment" $ do
      withMockReturning #executeDeployPlanMock [] $ do
        withServerSections
          [ ("foo", ServerSection "foo" (OnBranch branchName def True) Nothing False False [] [] [] Nothing Nothing),
            ("bar", onBranchSection "bar" branchName)
          ]
          $ do
            void $ createBuildsFor user name branchName commit [("foo", Nothing), ("bar", Nothing)]
            iAuth <- getInstallation $ Github.Data.Id 42
            let repoInfo = RepoInfo ForgeGithub (Just iAuth) (GhToken "test-token") user name
            let commitInfo = CommitInfo (getGhRepoOwner user) (RepoIsPublic True) repoInfo (Just branchName) Nothing commit
            void
              $ withPrivateNixXdgCache
              $ rolloutNewServerVersion mempty commitInfo (BranchDeployment branchName)
            (_, _, plan, _) <- fromSingleton <$> getMockCalls #executeDeployPlanMock
            Set.fromList
              ( plan
                  ^.. #toSpinUp
                    . each
                    . to ((^. #build . package) &&& (^. #domainIsPrimary))
              )
              `shouldBeM` Set.fromList [("foo", True), ("bar", False)]

  let wrap =
        inM
          . beforeM_ truncateDBM
          . aroundM_ suppressLogsWhenPassing
  describe "pull-request-deployments" $ wrap $ do
    let shouldHavePlan ::
          (HasCallStack) =>
          (Reporter, CommitInfo, DeployPlan, DeploymentType) ->
          (DeploymentType, [BuildId], [(CommitHash, PackageName)]) ->
          M ()
        shouldHavePlan (_, _, plan, deploymentType) expected =
          liftIO
            $ ( deploymentType,
                plan ^. #toSpinDown . to (fmap (^. configurationBuildId)),
                plan
                  ^. #toSpinUp
                    . to (fmap (\s -> (s ^. #build . gitCommit, s ^. #build . package)))
              )
            `shouldBe` expected
        planSpunUpBuildIds :: (a, b, DeployPlan, c) -> [BuildId]
        planSpunUpBuildIds (_, _, plan, _) = plan ^. #toSpinUp . to (fmap (^. #build . id))

    it "deploys servers for a PR with `on-pull-request`" $ do
      withMockReturning #executeDeployPlanMock [] $ do
        commit <- Deprecated.writeMockRemote "test-branch" def
        withServerSection "test-nix-config" (onPullRequestSection "test-nix-config") $ do
          _ <- testOverallBuild (mkPrEvent commit)
          _ <- testBuild $ \build ->
            build
              & fromPrEvent (mkPrEvent commit)
              & package .~ "test-nix-config"
              & uploadedToCache ?~ True
          Orchestrator.handlePullRequest mempty (mkCommitInfo commit) 42 >>= resolve
          [plan] <- getMockCalls #executeDeployPlanMock
          plan `shouldHavePlan` (GhPrDeployment 42, [], [(commit, "test-nix-config")])

    it "does not deploy when on-pull-request is not set" $ do
      withMockReturning #executeDeployPlanMock [] $ do
        commit <- Deprecated.writeMockRemote "test-branch" def
        withUnmatchingConfig $ do
          _ <- testOverallBuild (mkPrEvent commit)
          _ <- testBuild $ \build ->
            build
              & fromPrEvent (mkPrEvent commit)
              & package .~ "test-nix-config"
              & uploadedToCache ?~ True
          Orchestrator.handlePullRequest mempty (mkCommitInfo commit) 42 >>= resolve
          [plan] <- getMockCalls #executeDeployPlanMock
          plan `shouldHavePlan` (GhPrDeployment 42, [], [])

    -- Under nix-native discovery, "wanted" is derived FROM built
    -- nixosConfigurations' own deploySpecs rather than an independent
    -- declaration that could name a package no build matches — so there is
    -- no longer a "declared but never built" error case here (only a
    -- manual single-deployment redeploy target naming a stale package can
    -- still hit 'DeploymentWantsNixosConfigurationsThatDontExist', covered
    -- in the "persistence" context above). With no TypeNixosConfiguration
    -- build named "test-nix-config" at all, the plan is simply empty.
    it "does not deploy when no nixosConfiguration build exists for the PR" $ do
      withMockReturning #executeDeployPlanMock [] $ do
        commit <- Deprecated.writeMockRemote "test-branch" def
        withServerSection "test-nix-config" (onPullRequestSection "test-nix-config") $ do
          _ <- testBuild $ \build ->
            build
              & fromPrEvent (mkPrEvent commit)
              & package .~ "Build starting"
              & packageType .~ TypeOverall
          _ <- testBuild $ \build ->
            build
              & fromPrEvent (mkPrEvent commit)
              & package .~ "test-nix-conoofig"
              & packageType .~ TypePackage
              & uploadedToCache ?~ True
          Orchestrator.handlePullRequest mempty (mkCommitInfo commit) 42 >>= resolve
          [plan] <- getMockCalls #executeDeployPlanMock
          plan `shouldHavePlan` (GhPrDeployment 42, [], [])

    -- Regression: 'getDeployPlan's discovery poll (Deploy.hs) used to gate
    -- solely on the TypeOverall "Build starting" row reaching a terminal
    -- status. But Build/Flake.hs marks that row Success at REGISTRATION
    -- time, before any individual build has actually run — so a
    -- nixosConfiguration build that is still in flight (status = Nothing)
    -- was wrongly treated as part of a "finished" batch, and
    -- 'checkAllBuildsSucceeded' then threw "<package> has no status".
    -- Orchestrator.handlePullRequest rolls out PR servers concurrently with
    -- the push build, so this window is hit for real in production.
    it "waits for an in-flight nixosConfiguration build even though the TypeOverall build already finished" $ do
      withMockReturning #executeDeployPlanMock [] $ do
        commit <- Deprecated.writeMockRemote "test-branch" def
        withServerSection "test-nix-config" (onPullRequestSection "test-nix-config") $ do
          _ <- testOverallBuild (mkPrEvent commit)
          building <- testBuild $ \build ->
            build
              & fromPrEvent (mkPrEvent commit)
              & package .~ "test-nix-config"
              & status .~ Nothing
              & uploadedToCache ?~ False
          promise <- Orchestrator.handlePullRequest mempty (mkCommitInfo commit) 42
          -- Neither succeeds nor throws while the build is still in flight —
          -- this proves the poll is genuinely waiting, not merely "hasn't
          -- reached executeDeployPlan yet" (the pre-fix bug instead threw
          -- immediately out of checkAllBuildsSucceeded).
          raced <- timeout (fromSeconds @Int 5) (try (resolve promise))
          liftIO $ isNothing raced `shouldBe` True
          -- Now the build actually finishes; discovery may proceed.
          DB.reportBuildResultDB (building & status ?~ Success)
          DB.setBuildUploaded (building ^. id)
          final <- timeout (fromSeconds @Int 30) (try (resolve promise))
          liftIO $ case final of
            Just (Right ()) -> pure ()
            other -> expectationFailure $ cs $ "expected the rollout to proceed once the build finished, got: " <> show other
          [plan] <- getMockCalls #executeDeployPlanMock
          plan `shouldHavePlan` (GhPrDeployment 42, [], [(commit, "test-nix-config")])

    it "works if there are other (non-nixosConfig) packages with the same name" $ do
      withMockReturning #executeDeployPlanMock [] $ do
        commit <- Deprecated.writeMockRemote "test-branch" def
        withServerSection "test-nix-config" (onPullRequestSection "test-nix-config") $ do
          _ <- testOverallBuild (mkPrEvent commit)
          _ <- testBuild $ \build ->
            build
              & fromPrEvent (mkPrEvent commit)
              & package .~ "test-nix-config"
              & packageType .~ TypePackage
              & uploadedToCache ?~ True
          _ <- testBuild $ \build ->
            build
              & fromPrEvent (mkPrEvent commit)
              & package .~ "test-nix-config"
              & packageType .~ TypeNixosConfiguration
              & uploadedToCache ?~ True
          Orchestrator.handlePullRequest mempty (mkCommitInfo commit) 42 >>= resolve
          [plan] <- getMockCalls #executeDeployPlanMock
          plan `shouldHavePlan` (GhPrDeployment 42, [], [(commit, "test-nix-config")])

    it "does not deploy from external forks" $ do
      withMockReturning #executeDeployPlanMock [] $ do
        p <- emptyPromise
        withMockReturning #buildFlakeMock p $ do
          commit <- Deprecated.writeMockRemote "test-branch" def
          withServerSection "test-nix-config" (onPullRequestSection "test-nix-config") $ do
            let prEvent =
                  mkPullRequestEvent commit "test-branch" "other-owner/repo-fork" "owner/repo" testInstallationId
                    & number .~ 42
            _ <- testBuild $ \build ->
              build
                & fromPrEvent prEvent
                & package .~ "test-nix-config"
                & uploadedToCache ?~ True
            ghWebhookPullRequest prEvent >>= resolve
            calls <- getMockCalls #executeDeployPlanMock
            liftIO $ null calls `shouldBe` True

    it "does not deploy invalid subdomains" $ do
      withMockReturning #executeDeployPlanMock [] $ do
        commit <- Deprecated.writeMockRemote "test-branch" def
        withServerSection "foo/bar" (onPullRequestSection "foo/bar") $ do
          _ <- testOverallBuild (mkPrEvent commit)
          _ <- testBuild $ \build ->
            build
              & fromPrEvent (mkPrEvent commit)
              & package .~ "foo/bar"
              & uploadedToCache ?~ True
          result <- try $ Orchestrator.handlePullRequest mempty (mkCommitInfo commit) 42 >>= resolve
          liftIO $ first err result `shouldBe` Left (NameIsNotValidSubdomain PackageNameSubdomain "foo/bar")

    it "does deploy when (unused) branch name is not a valid subdomain" $ do
      withMockReturning #executeDeployPlanMock [] $ do
        commit <- Deprecated.writeMockRemote "sh/some-feature" def
        withServerSection "test-nix-config" (onPullRequestSection "test-nix-config") $ do
          let prEvent =
                mkPullRequestEvent commit "sh/some-feature" "test-owner/test-repo" "test-owner/test-repo" testInstallationId
                  & number .~ 42
          _ <- testOverallBuild prEvent
          _ <- testBuild $ \build ->
            build
              & fromPrEvent prEvent
              & package .~ "test-nix-config"
              & uploadedToCache ?~ True
          ghWebhookPullRequest prEvent >>= resolve
          [plan] <- getMockCalls #executeDeployPlanMock
          plan `shouldHavePlan` (GhPrDeployment 42, [], [(commit, "test-nix-config")])

    it "deploys multiple servers" $ do
      withMockReturning #executeDeployPlanMock [] $ do
        commit <- Deprecated.writeMockRemote "test-branch" def
        withServerSections
          [ ("pkg-a", onPullRequestSection "pkg-a"),
            ("pkg-b", onPullRequestSection "pkg-b")
          ]
          $ do
            let prEvent =
                  mkPullRequestEvent commit "test-branch" "test-owner/test-repo" "test-owner/test-repo" testInstallationId
                    & number .~ 42
            _ <- testOverallBuild prEvent
            _ <- testBuild $ \build ->
              build
                & fromPrEvent prEvent
                & package .~ "pkg-a"
                & uploadedToCache ?~ True
            _ <- testBuild $ \build ->
              build
                & fromPrEvent prEvent
                & package .~ "pkg-b"
                & uploadedToCache ?~ True
            ghWebhookPullRequest prEvent >>= resolve
            [plan] <- getMockCalls #executeDeployPlanMock
            plan `shouldHavePlan` (GhPrDeployment 42, [], [(commit, "pkg-a"), (commit, "pkg-b")])

    it "does not deploy any servers if a configuration fails" $ do
      withMockReturning #executeDeployPlanMock [] $ do
        commit <- Deprecated.writeMockRemote "test-branch" def
        withServerSection "test-nix-config" (onPullRequestSection "test-nix-config") $ do
          _ <- testOverallBuild (mkPrEvent commit)
          _build <- testBuild $ \build ->
            build
              & fromPrEvent (mkPrEvent commit)
              & package .~ "test-nix-config"
              & status ?~ Failure
              & uploadedToCache ?~ True
          promise <- Orchestrator.handlePullRequest mempty (mkCommitInfo commit) 42
          result <- try $ resolve promise
          liftIO $ first err result `shouldBe` Left (OtherError "test-nix-config failed")

    it "does not deploy any servers if a configuration times out" $ do
      withMockReturning #executeDeployPlanMock [] $ do
        commit <- Deprecated.writeMockRemote "test-branch" def
        withServerSection "test-nix-config" (onPullRequestSection "test-nix-config") $ do
          _ <- testOverallBuild (mkPrEvent commit)
          _build <- testBuild $ \build ->
            build
              & fromPrEvent (mkPrEvent commit)
              & package .~ "test-nix-config"
              & status ?~ Timeout
              & uploadedToCache ?~ True
          promise <- Orchestrator.handlePullRequest mempty (mkCommitInfo commit) 42
          result <- try $ resolve promise
          liftIO $ first err result `shouldBe` Left (OtherError "test-nix-config timed out")

    it "shuts down old servers from the same pull request" $ do
      withMockReturning #executeDeployPlanMock [] $ do
        commitA <- Deprecated.writeMockRemote "test-branch" def
        withServerSection "test-nix-config" (onPullRequestSection "test-nix-config") $ do
          let prEvent =
                mkPullRequestEvent commitA "test-branch" "test-owner/test-repo" "test-owner/test-repo" testInstallationId
                  & number .~ 42
          _ <- testOverallBuild prEvent
          buildA <- testBuild $ \build ->
            build
              & fromPrEvent prEvent
              & package .~ "test-nix-config"
              & uploadedToCache ?~ True
          ghWebhookPullRequest prEvent >>= resolve
          void $ addTestServer $ \server ->
            server
              & configurationBuildId .~ (buildA ^. id)
              & pullRequest ?~ GhPullRequestId (fromIntegral $ prEvent ^. number)

          mockRemote <- view #workingDir
          liftIO $ writeFile (mockRemote </> "some-added-file") "foo"
          commitB <- commitAll mockRemote
          let prEvent2 =
                mkPullRequestEvent commitB "test-branch" "test-owner/test-repo" "test-owner/test-repo" testInstallationId
                  & number .~ 42
          _ <- testOverallBuild prEvent2
          _ <- testBuild $ \build ->
            build
              & fromPrEvent prEvent2
              & package .~ "test-nix-config"
              & uploadedToCache ?~ True
          ghWebhookPullRequest prEvent2 >>= resolve
          [planA, planB] <- getMockCalls #executeDeployPlanMock
          planA `shouldHavePlan` (GhPrDeployment 42, [], [(commitA, "test-nix-config")])
          planB `shouldHavePlan` (GhPrDeployment 42, planSpunUpBuildIds planA, [(commitB, "test-nix-config")])

    it "does not shut down `on-branch` servers from the same branch" $ do
      withMockReturning #executeDeployPlanMock [] $ do
        commit <- Deprecated.writeMockRemote "test-branch" def
        withServerSection "test-nix-config" (onPullRequestSection "test-nix-config") $ do
          _ <- testOverallBuild (mkPrEvent commit)
          build <- testBuild $ \build ->
            build
              & fromPrEvent (mkPrEvent commit)
              & package .~ "test-nix-config"
              & uploadedToCache ?~ True
          void $ addTestServer $ \server ->
            server
              & configurationBuildId .~ (build ^. id)
          _ <- testBuild $ \build ->
            build
              & fromPrEvent (mkPrEvent commit)
              & package .~ "test-nix-config"
              & uploadedToCache ?~ True
          Orchestrator.handlePullRequest mempty (mkCommitInfo commit) 42 >>= resolve
          [plan] <- getMockCalls #executeDeployPlanMock
          plan `shouldHavePlan` (GhPrDeployment 42, [], [(commit, "test-nix-config")])

-- * Helpers

truncateDB :: IO ()
truncateDB = do
  withSystemTempDirectory "truncateDB" $ \tmp -> do
    withTestEnvironment tmp $ void . flip runM truncateDBM

withContext :: CheckSuiteEvent -> (RepoInfo -> Branch -> M a) -> M a
withContext event action = do
  let (owner, name) = event ^. eventRepoName
  let Just branch = event ^. eventBranch
  iAuth <- getInstallation $ Github.Data.Id 42
  let repoInfo = RepoInfo ForgeGithub (Just iAuth) (GhToken "test-token") owner name
  withPrivateNixXdgCache $ action repoInfo branch

doABuild :: Text -> CheckSuiteEvent -> RepoInfo -> M CommitInfo
doABuild flake event repoInfo = do
  _ <- Deprecated.writeMockRemote (fromJust $ event ^. eventBranch) (def :: GarnixConfig)
  dir <- view #workingDir
  liftIO $ T.writeFile (dir </> "flake.nix") flake
  commit <- commitAll dir
  event <- pure $ event & eventCommit .~ commit
  notifyOfCommit event
  pure
    $ CommitInfo
      { _commitInfoReqUser = GhLogin . whUserLogin $ senderOfEvent event,
        _commitInfoRepoPublicity = RepoIsPublic . not . whRepoIsPrivate $ repoForEvent event,
        _commitInfoRepoInfo = repoInfo,
        _commitInfoBranch = Branch <$> whCheckSuiteHeadBranch (evCheckSuiteCheckSuite event),
        _commitInfoPrFromFork = Nothing,
        _commitInfoCommit = commit
      }

getDeployLogsDB :: M [(ServerId, Text)]
getDeployLogsDB = do
  DB.pgQuery
    [pgSQL|!
      SELECT
        servers.id,
        servers.deploy_logs
      FROM servers
    |]

getAllDbServers :: M [ServerInfo]
getAllDbServers = do
  DB.pgQueryPrism
    _ServerInfo
    [pgSQL|!
    SELECT
      servers.id,
      servers.provisioner_id,
      servers.ipv4,
      servers.ipv6,
      servers.created_at,
      servers.ended_at,
      servers.configuration_build_id,
      servers.pull_request,
      servers.ready_at,
      builds.persistence_name,
      servers.server_tier,
      servers.is_primary
    FROM servers
    JOIN builds on servers.configuration_build_id = builds.id
    |]

assertNotExists :: (HasCallStack) => ServerInfo -> M ()
assertNotExists serverInfo = liftIO $ do
  let st = _getProvisionerState provisionerMockState
  let provisionerId = serverInfo ^. provisionedServerId
  readMVar st >>= \m -> case Map.lookup provisionerId m of
    Nothing -> pure ()
    Just (tid, state, mvar) -> do
      actualState <- liftIO $ readMVar mvar
      assertFailure $ "assertNotExists: server exists: " <> cs (show (threadId tid, state, actualState))

shouldHaveState :: (HasCallStack) => ServerInfo -> Text -> M ()
shouldHaveState serverInfo expectedState = liftIO $ do
  let st = _getProvisionerState provisionerMockState
  let provisionerId = serverInfo ^. provisionedServerId
  readMVar st >>= \m -> case Map.lookup provisionerId m of
    Nothing ->
      expectationFailure
        . cs
        $ "Expected to find a container with ID: "
        <> show (serverInfo ^. id)
    Just (_, _, mvar) -> do
      actualState <- liftIO $ readMVar mvar
      actualState `shouldBe` expectedState

simpleFlake :: Text
simpleFlake = simpleFlake' "A simple flake"

virtualisationModules :: Text
virtualisationModules =
  cs
    [i|
      "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
      {
        virtualisation.useNixStoreImage = true;
        virtualisation.writableStore = true;
        # switch-to-configuration-ng (nixpkgs 26.05-small, 2026-07) intermittently
        # fails restarting systemd-udevd and its coupled control/kernel sockets
        # during a switch onto the already-running guest (the sockets can't
        # rebind while udevd still holds them), exiting 4 and flaking @slow
        # activations. Pin udevd across the switch so it (and its Sockets=) are
        # left running. `restartIfChanged` is a service-only option; the sockets
        # have none, but are restarted as a consequence of the service restart.
        # Test guests only; production uses microvm.nix guests, which don't hit this.
        systemd.services.systemd-udevd.restartIfChanged = false;
      }
    |]

simpleFlake' :: Text -> Text
simpleFlake' description' =
  cs
    [i|
  {
    description = "#{description'}";
    # If you update this, update also places where it matches.
    # Search for INNER_NIXPKGS_MATCHES
    inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05-small";

    outputs = { self, nixpkgs }: {

      nixosConfigurations = {
        default = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            #{virtualisationModules}
            ({ pkgs, ... } : {
              boot.isContainer = true;
              services.openssh.enable = true;
              users.users.root = {
                openssh.authorizedKeys.keys = [
                   "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC2sZYF9l/ssO+uk5bdaZLskJKxNFbbJDd3cR1TR17KE1elmC4KQ7LOU3329JMyiDU73DlUHRG+1zhN9I6UNCJR8en7YDPWODw+1eKAFI1IQiYuuvp3rO9RnR5DYXxzGjEBuxxxOqLRCLmaWsP4nQ6kzmmWvIYZ9npNLCp1KN42EcCzlpUR4NOqxJr834vkqlgk3dnl00wYlLO5v4+t0l48SrcUL8EM7z/i0ivjT/15sl6PgNSgTGbB6eIWg9oLt76rhXpGvvccCp/atDb98+OXlPpDw90MgO0sGA8UyAFAKrpoLaNTPFyRrCBlHLIBlvgagNaYoq6DOGJVOGK227tJMiwDnhUyOirutYnIJ6MNdUGmq2bF7nX15uXGmGKfHf4TaShgMCcitlsrzVwuO/gdce1Y5TnJc/Wdbj3D8j95/41bBp6MyRlUK5gpT0R+NSX1hv0rL+eSa56REwfcZMrYWFr3Hpv7eq9VHAS0NBj+Hy5N9JCc+mvB7w2XufNoMkk= jkarni@janus"
                ];
              };
            })
          ];
        };
      };
    };
  }

|]

flakeWithFailingBuilds :: Text
flakeWithFailingBuilds =
  cs
    [i|
  {
    # If you update this, update also places where it matches.
    # Search for INNER_NIXPKGS_MATCHES
    inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05-small";

    outputs = { self, nixpkgs }: {
      packages.x86_64-linux.failing = derivation {
      };

      nixosConfigurations = {
        myHost = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            #{virtualisationModules}
            ({ pkgs, ... } : {
              boot.isContainer = true;
              services.openssh.enable = true;
              users.users.root = {
                openssh.authorizedKeys.keys = [
                   "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC2sZYF9l/ssO+uk5bdaZLskJKxNFbbJDd3cR1TR17KE1elmC4KQ7LOU3329JMyiDU73DlUHRG+1zhN9I6UNCJR8en7YDPWODw+1eKAFI1IQiYuuvp3rO9RnR5DYXxzGjEBuxxxOqLRCLmaWsP4nQ6kzmmWvIYZ9npNLCp1KN42EcCzlpUR4NOqxJr834vkqlgk3dnl00wYlLO5v4+t0l48SrcUL8EM7z/i0ivjT/15sl6PgNSgTGbB6eIWg9oLt76rhXpGvvccCp/atDb98+OXlPpDw90MgO0sGA8UyAFAKrpoLaNTPFyRrCBlHLIBlvgagNaYoq6DOGJVOGK227tJMiwDnhUyOirutYnIJ6MNdUGmq2bF7nX15uXGmGKfHf4TaShgMCcitlsrzVwuO/gdce1Y5TnJc/Wdbj3D8j95/41bBp6MyRlUK5gpT0R+NSX1hv0rL+eSa56REwfcZMrYWFr3Hpv7eq9VHAS0NBj+Hy5N9JCc+mvB7w2XufNoMkk= jkarni@janus"
                ];
              };
            })
          ];
        };
      };
    };
  }

|]

flakeWithFailingActivation :: Text
flakeWithFailingActivation =
  cs
    [i|
      {
        # If you update this, update also places where it matches.
        # Search for INNER_NIXPKGS_MATCHES
        inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05-small";

        outputs = { self, nixpkgs }: {

          nixosConfigurations = {
            default = nixpkgs.lib.nixosSystem {
              system = "x86_64-linux";
              modules = [
                #{virtualisationModules}
                ({ pkgs, ... } : {
                  boot.isContainer = true;
                  system.activationScripts.activationFailure.text = ''
                    activationFailure
                  '';
                })
              ];
            };
          };
        };
      }
    |]

flakeWithPersistence :: Bool -> Text -> PackageName -> Text -> Text
flakeWithPersistence enable name (PackageName package) t =
  cs
    [i|
{
  inputs = {
    # If you update this, update also places where it matches.
    # Search for INNER_NIXPKGS_MATCHES
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05-small";
    garnix.url = "github:garnix-io/garnix-lib/d3f3a98a0baddb3bdc6e0d028d1b58251a1d86f5";
  };

  outputs =
    { self, nixpkgs, garnix }: {

      nixosConfigurations."#{package}" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          #{virtualisationModules}
          garnix.nixosModules.garnix
          {
            config = {
              boot.isContainer = true;

              #{sshKey}

              # something that we can safely modify to get a different hash
              networking.hostName = "#{t}";

              garnix.server = {
                 enable = #{if enable then "true" :: String else "false"};
                 isVM = true;
                 persistence = {
                  enable = #{if enable then "true" :: String else "false"};
                  name = "#{name}";
                };
              };
            };
          }
        ];

      };
    };
}
    |]
  where
    sshKey :: String
    sshKey =
      if enable
        then
          [i|
              users.users.garnix.openssh.authorizedKeys.keys = [
                   "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC2sZYF9l/ssO+uk5bdaZLskJKxNFbbJDd3cR1TR17KE1elmC4KQ7LOU3329JMyiDU73DlUHRG+1zhN9I6UNCJR8en7YDPWODw+1eKAFI1IQiYuuvp3rO9RnR5DYXxzGjEBuxxxOqLRCLmaWsP4nQ6kzmmWvIYZ9npNLCp1KN42EcCzlpUR4NOqxJr834vkqlgk3dnl00wYlLO5v4+t0l48SrcUL8EM7z/i0ivjT/15sl6PgNSgTGbB6eIWg9oLt76rhXpGvvccCp/atDb98+OXlPpDw90MgO0sGA8UyAFAKrpoLaNTPFyRrCBlHLIBlvgagNaYoq6DOGJVOGK227tJMiwDnhUyOirutYnIJ6MNdUGmq2bF7nX15uXGmGKfHf4TaShgMCcitlsrzVwuO/gdce1Y5TnJc/Wdbj3D8j95/41bBp6MyRlUK5gpT0R+NSX1hv0rL+eSa56REwfcZMrYWFr3Hpv7eq9VHAS0NBj+Hy5N9JCc+mvB7w2XufNoMkk= jkarni@janus"
              ];
      |]
        else ""

makeMultiFlake :: [PackageName] -> Text
makeMultiFlake packages = cs buildFile
  where
    buildFile :: String
    buildFile = start <> foldMap buildEntry packages <> end

    start :: String
    start =
      [i|
  {
    description = "simple description here";
    # If you update this, update also places where it matches.
    # Search for INNER_NIXPKGS_MATCHES
    inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05-small";

    outputs = { self, nixpkgs }: {

      nixosConfigurations = {
     |]

    end :: String
    end =
      [i|
      };
    };
  }
     |]

    buildEntry :: PackageName -> String
    buildEntry (PackageName pkg) =
      [i|
        #{pkg} = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            #{virtualisationModules}
            ({ pkgs, ... } : {
              boot.isContainer = true;
              services.openssh.enable = true;
              users.users.root = {
                openssh.authorizedKeys.keys = [
                   "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC2sZYF9l/ssO+uk5bdaZLskJKxNFbbJDd3cR1TR17KE1elmC4KQ7LOU3329JMyiDU73DlUHRG+1zhN9I6UNCJR8en7YDPWODw+1eKAFI1IQiYuuvp3rO9RnR5DYXxzGjEBuxxxOqLRCLmaWsP4nQ6kzmmWvIYZ9npNLCp1KN42EcCzlpUR4NOqxJr834vkqlgk3dnl00wYlLO5v4+t0l48SrcUL8EM7z/i0ivjT/15sl6PgNSgTGbB6eIWg9oLt76rhXpGvvccCp/atDb98+OXlPpDw90MgO0sGA8UyAFAKrpoLaNTPFyRrCBlHLIBlvgagNaYoq6DOGJVOGK227tJMiwDnhUyOirutYnIJ6MNdUGmq2bF7nX15uXGmGKfHf4TaShgMCcitlsrzVwuO/gdce1Y5TnJc/Wdbj3D8j95/41bBp6MyRlUK5gpT0R+NSX1hv0rL+eSa56REwfcZMrYWFr3Hpv7eq9VHAS0NBj+Hy5N9JCc+mvB7w2XufNoMkk= jkarni@janus"
                ];
              };
            })
          ];
        };

       |]

-- | Build the nix-native `garnix.server.deploySpec` JSON that
-- 'Garnix.YamlConfig.decodeDeploySpec' would decode back into the given
-- 'ServerSection' — the shape provisioner/guest-profile.nix renders (see
-- 182e616 and docs/plans/2026-07-27-nix-native-server-config-design.md
-- §2-3). The `configuration` field isn't part of the real aggregate
-- (implicit — whichever nixosConfiguration was evaluated), so it isn't
-- encoded here either; the caller supplies it as the mock's lookup key.
-- `persistenceName` mirrors the deploySpec's own `persistence.{enable,name}`
-- sub-object (independent of `ServerSection`, exactly like production:
-- persistence isn't one of 'ServerSection's fields either — see
-- 'Garnix.Build.Package.persistenceNameFromDeploySpec').
encodeDeploySpec :: Maybe Text -> ServerSection -> Aeson.Value
encodeDeploySpec persistenceName section =
  Aeson.object
    [ "deployment" Aeson..= toJSONViaCodec (_serverSectionDeploySection section),
      "domains" Aeson..= _serverSectionDomains section,
      "exposeSSH" Aeson..= _serverSectionExposeSSH section,
      "authorizeDeployerGithubKeys" Aeson..= _serverSectionAuthorizeDeployerGithubKeys section,
      "authorizedSSHKeys" Aeson..= _serverSectionAuthorizedSSHKeys section,
      "ports" Aeson..= toJSONViaCodec (_serverSectionPorts section),
      "applicationLog" Aeson..= (encodeAppLog <$> _serverSectionLogFile section),
      "backups" Aeson..= _serverSectionBackups section,
      "authentikDefault" Aeson..= (_serverSectionAuthentikSection section == Just "default"),
      "persistence" Aeson..= Aeson.object ["enable" Aeson..= isJust persistenceName, "name" Aeson..= persistenceName]
    ]
  where
    encodeAppLog (ServerLogFile path) = Aeson.object ["enable" Aeson..= True, "path" Aeson..= path]

-- | Mock the deploySpec discovery seam (see
-- 'Garnix.Monad.discoverDeploySpecMock') so specific packages resolve to
-- exactly the given 'ServerSection's (plus an optional persistence name,
-- rendered into the same aggregate — see 'encodeDeploySpec'), and nothing
-- else — the nix-native replacement for writing a `servers:` yaml section
-- (removed from the schema entirely, §3). Packages not listed resolve to
-- 'Nothing' (not a server), same as a build whose nixosConfiguration never
-- imported the guest module. This is the ONE discovery seam shared by both
-- 'Garnix.Build.Package' (persistence capture, at build time) and
-- 'Garnix.Hosting.Deploy' (deploy planning) — mocking it here stands in for
-- BOTH real `nix eval`s at once, so a persistence name set here is what a
-- real build's `getPersistenceName` would also have captured.
withServerSectionsAndPersistence :: [(PackageName, ServerSection, Maybe Text)] -> M a -> M a
withServerSectionsAndPersistence entries =
  withMock #discoverDeploySpecMock $ \(_flakeDir, pkg) ->
    pure $ case [(section, persistenceName) | (k, section, persistenceName) <- entries, k == pkg] of
      (section, persistenceName) : _ -> Just (encodeDeploySpec persistenceName section)
      [] -> Nothing

withServerSections :: [(PackageName, ServerSection)] -> M a -> M a
withServerSections sections = withServerSectionsAndPersistence [(pkg, section, Nothing) | (pkg, section) <- sections]

withServerSection :: PackageName -> ServerSection -> M a -> M a
withServerSection pkg section = withServerSections [(pkg, section)]

withServerSectionAndPersistence :: PackageName -> ServerSection -> Maybe Text -> M a -> M a
withServerSectionAndPersistence pkg section persistenceName = withServerSectionsAndPersistence [(pkg, section, persistenceName)]

-- | A default on-branch server section for `pkg`, deploying from `branch`
-- with i1x2/no extras — mirrors what a bare
-- `servers:\n  - configuration: pkg\n    deployment: {type: on-branch, branch}`
-- yaml entry used to produce.
onBranchSection :: PackageName -> Branch -> ServerSection
onBranchSection pkg branch = ServerSection pkg (OnBranch branch def False) Nothing False False [] [] [] Nothing Nothing

onPullRequestSection :: PackageName -> ServerSection
onPullRequestSection pkg = ServerSection pkg (OnPullRequest def) Nothing False False [] [] [] Nothing Nothing

-- | Mocks a single `pkg` as an on-branch server for `branch` for the
-- duration of `action` — the nix-native replacement for
-- @writeMatchingConfig branch pkg@ followed by unscoped later reads.
withMatchingConfig :: Branch -> PackageName -> M a -> M a
withMatchingConfig branch pkg = withServerSection pkg (onBranchSection pkg branch)

-- | No package resolves to a server — the nix-native replacement for
-- @writeUnmatchingConfig@ (an empty `servers: []`).
withUnmatchingConfig :: M a -> M a
withUnmatchingConfig = withServerSections []

-- | Mocks every listed `pkg` as an on-branch server for `branch` — the
-- nix-native replacement for @writeMultiConfig@.
withMultiConfig :: Branch -> [PackageName] -> M a -> M a
withMultiConfig branch packages = withServerSections [(pkg, onBranchSection pkg branch) | pkg <- packages]

startServerAndFailOnAllExcept ::
  MVar () ->
  PackageName ->
  (Reporter, CommitInfo, DeploymentType, ServerToSpinUp) ->
  M ServerInfo
startServerAndFailOnAllExcept sync provision (reporter, commitInfo, deploymentType, serverToSpinUp) = do
  if serverToSpinUp ^. #build . package == provision
    then do
      result <- withUnmock #startServerMock $ startServer reporter commitInfo deploymentType serverToSpinUp
      liftIO $ putMVar sync ()
      pure result
    else do
      _ <- liftIO $ readMVar sync
      throw $ ProvisioningError "test error"

createBuildsFor :: GhRepoOwner -> GhRepoName -> Branch -> CommitHash -> [(PackageName, Maybe Text)] -> M [Build]
createBuildsFor user name branchName commit machines = do
  overallBuild <- testBuild $ \build ->
    build
      & repoUser .~ user
      & repoName .~ name
      & gitCommit .~ commit
      & branch ?~ branchName
      & status ?~ Success
      & packageType .~ TypeOverall
      & package .~ "overall package"

  forM machines $ \(machine, pname) -> do
    testBuild $ \_ ->
      overallBuild
        & packageType .~ TypeNixosConfiguration
        & package .~ machine
        & persistenceName .~ pname
        & uploadedToCache ?~ True

deployNewServerFor ::
  GhRepoOwner ->
  GhRepoName ->
  Branch ->
  CommitHash ->
  [(PackageName, Maybe Text)] ->
  M [ServerInfo]
deployNewServerFor user name branchName commit machineNames = withMultiConfig branchName (fmap fst machineNames) $ do
  void $ createBuildsFor user name branchName commit machineNames
  iAuth <- getInstallation $ Github.Data.Id 42
  let repoInfo = RepoInfo ForgeGithub (Just iAuth) (GhToken "test-token") user name
  let commitInfo = CommitInfo (getGhRepoOwner user) (RepoIsPublic True) repoInfo (Just branchName) Nothing commit
  withPrivateNixXdgCache
    $ rolloutNewServerVersion mempty commitInfo (BranchDeployment branchName)

mkPrEvent :: CommitHash -> PullRequestEvent
mkPrEvent commit =
  mkPullRequestEvent commit "test-branch" "test-owner/test-repo" "test-owner/test-repo" testInstallationId
    & number .~ 42

testInstallationId :: Int
testInstallationId = 123456

fromPrEvent :: PullRequestEvent -> Build -> Build
fromPrEvent prEvent build =
  build
    & branch ?~ Branch (prEvent ^. payload . head . ref)
    & packageType .~ TypeNixosConfiguration
    & repoUser .~ "test-owner"
    & repoName .~ "test-repo"
    & gitCommit .~ CommitHash (prEvent ^. payload . head . sha)
    & uploadedToCache ?~ True

-- | 'getDeployPlan's discovery poll (Deploy.hs) waits for a `TypeOverall`
-- "Build starting" row to reach a terminal status before it treats a
-- commit's nixosConfiguration builds as complete — the real build pipeline
-- always registers one (via `setupBuilds`) before any build starts, so
-- this is what production actually guarantees the poll can rely on. Tests
-- that fabricate builds directly via 'testBuild' (bypassing the real
-- pipeline, e.g. everything in "pull-request-deployments" below) must
-- create this row too, or the poll never terminates.
testOverallBuild :: PullRequestEvent -> M Build
testOverallBuild prEvent =
  testBuild $ \build ->
    build
      & fromPrEvent prEvent
      & package .~ "Build starting"
      & packageType .~ TypeOverall

mkCommitInfo :: CommitHash -> CommitInfo
mkCommitInfo commitHash =
  defaultCommitInfo
    & commit .~ commitHash
    & branch .~ Nothing
    & reqUser .~ "test-owner"
    & repoInfo . ghRepoOwner .~ "test-owner"
    & repoInfo . ghRepoName .~ "test-repo"
