module Garnix.DBSpec (spec) where

import Control.Concurrent.Async.Lifted (replicateConcurrently)
import Control.Exception qualified as E
import Control.Monad.Trans.Control (liftBaseDiscard)
import Data.Set qualified as Set
import Database.PostgreSQL.Typed
import Database.PostgreSQL.Typed qualified as PSQL
import Garnix.DB qualified as DB
import Garnix.Monad (M, throw)
import Garnix.Nix.Types (DrvPath (..), StoreHash (..), StorePath (..))
import Garnix.Prelude
import Garnix.TestHelpers (addTestServer, defaultCommitInfo, testBuild, truncateDBM)
import Garnix.TestHelpers.Monad (beforeM_, inM, shouldBeM, shouldReturnM)
import Garnix.Types hiding (context, head)
import System.Environment (getEnv)
import System.IO.Silently (hSilence)
import Test.Hspec
import Test.Mockery.Environment (withEnvironment)
import Test.QuickCheck (generate, shuffle)

spec :: Spec
spec = do
  describe "private-input fork approval requests" $ inM $ beforeM_ truncateDBM $ do
    it "records only actually blocked forks and forces the base repo cache private" $ do
      DB.getPrivateInputForkApprovalRequests `shouldReturnM` []
      DB.recordPrivateInputForkBlock "owner" "repo" (PrFromFork "someone/fork")
      requests <- DB.getPrivateInputForkApprovalRequests
      fmap (\(owner, repo, forkFullName, allowed, _blockedAt) -> (owner, repo, forkFullName, allowed)) requests
        `shouldBeM` [("owner", "repo", "someone/fork", False)]
      config <- DB.getRepoConfig "owner" "repo"
      config ^. privateCache `shouldBeM` True
      config ^. skipPrivateInputsCheckForCollaborators `shouldBeM` False

    it "approves and revokes a recorded fork without setting the repo-wide flag" $ do
      DB.ensureRepoPrivateCache "automatic" "repo"
      DB.getPrivateInputForkApprovalRequests `shouldReturnM` []

      DB.recordPrivateInputForkBlock "blocked" "repo" (PrFromFork "forkowner/fork")
      DB.setPrivateInputForkApproval "blocked" "repo" (PrFromFork "forkowner/fork") True
      approved <- DB.getPrivateInputForkApprovalRequests
      fmap (\(owner, repo, forkFullName, allowed, _blockedAt) -> (owner, repo, forkFullName, allowed)) approved
        `shouldBeM` [("blocked", "repo", "forkowner/fork", True)]
      approvedConfig <- DB.getRepoConfig "blocked" "repo"
      approvedConfig ^. privateCache `shouldBeM` True
      -- Per-fork approval must NOT flip the repo-wide collaborator-skip flag.
      approvedConfig ^. skipPrivateInputsCheckForCollaborators `shouldBeM` False

      DB.setPrivateInputForkApproval "blocked" "repo" (PrFromFork "forkowner/fork") False
      revoked <- DB.getPrivateInputForkApprovalRequests
      fmap (\(owner, repo, forkFullName, allowed, _blockedAt) -> (owner, repo, forkFullName, allowed)) revoked
        `shouldBeM` [("blocked", "repo", "forkowner/fork", False)]

    it "approves each fork of the same repo independently" $ do
      DB.recordPrivateInputForkBlock "owner" "repo" (PrFromFork "forkA/fork")
      DB.recordPrivateInputForkBlock "owner" "repo" (PrFromFork "forkB/fork")
      DB.setPrivateInputForkApproval "owner" "repo" (PrFromFork "forkA/fork") True

      -- Approving fork A must not approve fork B of the same base repo.
      DB.isPrivateInputForkApproved "owner" "repo" (PrFromFork "forkA/fork") `shouldReturnM` True
      DB.isPrivateInputForkApproved "owner" "repo" (PrFromFork "forkB/fork") `shouldReturnM` False

  describe "newBuild" $ inM $ beforeM_ truncateDBM $ do
    it "allows duplicate builds" $ do
      user <-
        DB.newUser
          (GhLogin "user")
          (Email "foo@x.com")
          FreeSubscription
          True
      let go =
            DB.newBuildDB
              ( CommitInfo
                  (user ^. githubLogin)
                  (RepoIsPublic True)
                  ( RepoInfo
                      ForgeGithub
                      Nothing
                      undefined
                      (GhRepoOwner $ GhLogin "foo")
                      (GhRepoName "bar")
                  )
                  (Just (Branch "branch/name"))
                  Nothing
                  (CommitHash "baz")
              )
              (PackageInfo TypePackage (IsSystem X8664Linux) (PackageName "quux"))
              "garnix-server-test"
              False
      void go
      void go

  context "pgTransaction" $ inM $ beforeM_ truncateDBM $ do
    it "rolls transactions back when throwing errors in M" $ do
      (void . try . DB.pgTransaction) $ do
        void
          $ DB.pgQuery
            [pgSQL|
              INSERT INTO heartbeat
                (hostname, last_heartbeat)
                VALUES ('test', NOW())
            |]
        throw $ OtherError "testing"
      hb <- DB.getRecentHeartbeats
      liftIO $ hb `shouldBe` []

    it "rolls transactions back due to SQL errors" $ do
      (void . liftBaseDiscard (E.try @PGError) . DB.pgTransaction) $ do
        void
          $ DB.pgQuery
            [pgSQL|
        INSERT INTO heartbeat
          (hostname, last_heartbeat)
          VALUES ('test', NOW())
          |]
        -- Second insert violates the heartbeat primary key (hostname), which
        -- raises a PGError and must roll back the whole transaction.
        void
          $ DB.pgQuery
            [pgSQL|
        INSERT INTO heartbeat
          (hostname, last_heartbeat)
          VALUES ('test', NOW())
          |]
      hb <- DB.getRecentHeartbeats
      liftIO $ hb `shouldBe` []

  context "getUserInternalToken" $ inM $ beforeM_ truncateDBM $ do
    it "gets the same token when called by multiple threads concurrently" $ do
      results <- replicateConcurrently 50 (DB.getUserInternalToken $ GhLogin "user")
      liftIO $ results `shouldBe` replicate 50 (head results)

  context "claimS3CachedStorePaths" $ inM $ beforeM_ truncateDBM $ do
    let getCacheEntries :: M [(Text, Maybe Text, Maybe UTCTime)]
        getCacheEntries =
          DB.pgQuery
            [pgSQL|
          SELECT hash, package_name, uploaded_at FROM cache_store_hashes
            |]
    it "never returns the same store path in different calls" $ do
      let storePaths = [StorePath (StoreHash $ show n) (show n) | n <- [1 :: Int .. 100]]
      returned <- replicateConcurrently 100 $ do
        shuffled <- liftIO $ generate $ shuffle storePaths
        DB.claimS3CachedStorePaths shuffled
      liftIO $ sort (mconcat returned) `shouldBe` sort storePaths

    it "returns existing old-style cache entries" $ do
      void
        $ DB.pgQuery
          [pgSQL|
        INSERT INTO cache_store_hashes
          (hash)
          VALUES ('foo')
          |]
      let storePaths = [StorePath (StoreHash "foo") "bar"]
      claimed <- DB.claimS3CachedStorePaths storePaths
      liftIO $ claimed `shouldBe` storePaths

      getCacheEntries `shouldReturnM` [("foo", Just "bar", Nothing)]

    it "doesn't return recent new-style cache entries that have not been uploaded yet" $ do
      void
        $ DB.pgQuery
          [pgSQL|
        INSERT INTO cache_store_hashes
          (hash, package_name)
          VALUES ('foo', 'bar')
          |]
      let storePaths = [StorePath (StoreHash "foo") "bar"]
      claimed <- DB.claimS3CachedStorePaths storePaths
      liftIO $ claimed `shouldBe` []

      getCacheEntries `shouldReturnM` [("foo", Just "bar", Nothing)]

    it "return stale new-style cache entries that have not been uploaded yet" $ do
      (void . liftBaseDiscard (E.try @PGError) . DB.pgTransaction) $ do
        void
          $ DB.pgQuery
            [pgSQL|
        INSERT INTO cache_store_hashes
          (hash, package_name, created_at)
          VALUES ('foo', 'bar', now() - interval '5 days')
          |]
      let storePaths = [StorePath (StoreHash "foo") "bar"]
      claimed <- DB.claimS3CachedStorePaths storePaths
      liftIO $ claimed `shouldBe` storePaths

      getCacheEntries `shouldReturnM` [("foo", Just "bar", Nothing)]

  context "getIncrementalTarget" $ inM $ beforeM_ truncateDBM $ do
    it "returns nothing if no matching commit exists" $ do
      now <- liftIO getCurrentTime
      baseBuild <- testBuild identity
      void $ testBuild ((gitCommit .~ "aaaa") . (endTime ?~ now))
      void $ testBuild ((gitCommit .~ "bbbb") . (endTime ?~ now))
      DB.getIncrementalTarget baseBuild ["cccc", "dddd"] `shouldReturnM` []

    it "returns the matching commit if one exists" $ do
      now <- liftIO getCurrentTime
      baseBuild <- testBuild identity
      build <- testBuild ((gitCommit .~ "aaaa") . (endTime ?~ now))
      DB.getIncrementalTarget baseBuild ["aaaa"] `shouldReturnM` [build]

    it "returns the first one in the argument list if multiple match" $ do
      now <- liftIO getCurrentTime
      baseBuild <- testBuild identity
      build <- testBuild ((gitCommit .~ "aaaa") . (endTime ?~ now))
      _ <- testBuild ((gitCommit .~ "bbbb") . (endTime ?~ now))
      DB.getIncrementalTarget baseBuild ["aaaa", "bbbb"] `shouldReturnM` [build]

    it "does not return builds from a commit for which not all builds have finished" $ do
      now <- liftIO getCurrentTime
      baseBuild <- testBuild identity
      _ <- testBuild (gitCommit .~ "aaaa")
      _ <- testBuild ((gitCommit .~ "aaaa") . (package .~ "blah") . (endTime ?~ now))
      build <- testBuild ((gitCommit .~ "bbbb") . (endTime ?~ now))
      DB.getIncrementalTarget baseBuild ["aaaa", "bbbb"] `shouldReturnM` [build]

    it "returns all the builds for a given commit ignoring duplicates" $ do
      now <- liftIO getCurrentTime
      baseBuild <- testBuild identity
      build1 <- testBuild ((gitCommit .~ "aaaa") . (endTime ?~ now) . (package .~ "foo"))
      _ <- testBuild ((gitCommit .~ "aaaa") . (endTime ?~ now) . (package .~ "foo"))
      build2 <- testBuild ((gitCommit .~ "aaaa") . (endTime ?~ now) . (package .~ "bar"))
      res <- DB.getIncrementalTarget baseBuild ["aaaa", "bbbb"]
      sort (res ^.. traverse . package) `shouldBeM` sort ([build1, build2] ^.. traverse . package)

    it "does not return builds from a different repo even if the commit is the same" $ do
      now <- liftIO getCurrentTime
      build <- testBuild ((gitCommit .~ "aaaa") . (endTime ?~ now))
      DB.getIncrementalTarget (build & repoName .~ "somethingelse") ["aaaa"] `shouldReturnM` []

  -- `truncateDBM` doesn't clear `runs` (it has no FK ties to the tables it
  -- lists, so nothing forces it in); clear it explicitly so the counts below
  -- are exact.
  describe "orphaned build/run resumability" $ inM $ beforeM_ truncateDBM $ do
    it "restarts setup if the backend stopped before creating the commit row" $ do
      void $ DB.pgExec [pgSQL| TRUNCATE runs |]
      overall <- testBuild ((status .~ Nothing) . (packageType .~ TypeOverall) . (package .~ "overall"))

      DB.getInterruptedEvaluatingBuilds `shouldReturnM` [overall]

    it "restarts an interrupted commit setup instead of resuming its partial package rows" $ do
      void $ DB.pgExec [pgSQL| TRUNCATE runs |]
      DB.newCommit "test-owner" "test-repo" "aaaaaa"

      overall <- testBuild ((status .~ Nothing) . (packageType .~ TypeOverall) . (package .~ "overall"))
      partialPackage <- testBuild ((status .~ Nothing) . (package .~ "partial"))

      DB.getInterruptedEvaluatingBuilds `shouldReturnM` [overall]
      DB.getResumableOrphanedBuilds `shouldReturnM` []

      (cancelledBuilds, cancelledRuns) <- DB.cancelOrphanedWork
      cancelledBuilds `shouldBeM` 2
      cancelledRuns `shouldBeM` 0
      cancelledPartial <- DB.getBuild (partialPackage ^. id)
      cancelledPartial ^. status `shouldBeM` Just Cancelled

    it "restarts a legacy interrupted setup after its partial rows were already recovered" $ do
      void $ DB.pgExec [pgSQL| TRUNCATE runs |]
      DB.newCommit "test-owner" "test-repo" "aaaaaa"

      overall <- testBuild ((status ?~ Cancelled) . (packageType .~ TypeOverall) . (package .~ "overall"))
      void $ testBuild ((status ?~ Success) . (package .~ "partial"))

      DB.getInterruptedEvaluatingBuilds `shouldReturnM` [overall]

    it "does not restart an evaluating commit that the user cancelled" $ do
      void $ DB.pgExec [pgSQL| TRUNCATE runs |]
      DB.newCommit "test-owner" "test-repo" "aaaaaa"

      void $ testBuild ((status ?~ Cancelled) . (packageType .~ TypeOverall) . (package .~ "overall"))
      void $ testBuild ((status ?~ Cancelled) . (package .~ "partial"))

      DB.getInterruptedEvaluatingBuilds `shouldReturnM` []

    it "resumes package builds for a fully evaluated commit, while cancelling overall rows and runs" $ do
      void $ DB.pgExec [pgSQL| TRUNCATE runs |]
      DB.newCommit "test-owner" "test-repo" "aaaaaa"
      DB.setCommitStatus "test-owner" "test-repo" "aaaaaa" Evaluated

      resumableWithDrv <- testBuild ((status .~ Nothing) . (drvPath ?~ "/nix/store/00000000000000000000000000000000-foo.drv"))
      resumableBeforeEval <- testBuild ((status .~ Nothing) . (package .~ "before-eval"))
      unresumableOverall <- testBuild ((status .~ Nothing) . (packageType .~ TypeOverall) . (package .~ "overall"))
      finished <- testBuild (status ?~ Success)
      run <- DB.newRun "test-run" defaultCommitInfo

      -- Package rows are restartable by re-evaluating when drv_path is absent.
      -- The derivation checkpoint is an optimization, not a correctness gate.
      DB.getResumableOrphanedBuilds `shouldReturnM` [resumableWithDrv, resumableBeforeEval]

      (cancelledBuilds, cancelledRuns) <- DB.cancelOrphanedWork
      cancelledBuilds `shouldBeM` 1
      cancelledRuns `shouldBeM` 1

      -- Both package rows are left orphaned for startup recovery.
      DB.getBuild (resumableWithDrv ^. id) `shouldReturnM` resumableWithDrv
      DB.getBuild (resumableBeforeEval ^. id) `shouldReturnM` resumableBeforeEval

      -- The synthetic overall row cannot be passed to package doBuild and is
      -- terminalized; its component package rows determine the final result.
      cancelledOverall <- DB.getBuild (unresumableOverall ^. id)
      cancelledOverall ^. status `shouldBeM` Just Cancelled

      -- an already-terminal build is untouched
      DB.getBuild (finished ^. id) `shouldReturnM` finished

      -- the orphaned run (runs have no drv_path to re-attach to, so they're
      -- always unresumable) got cancelled
      runAfter <- DB.getRun (run ^. id)
      case runAfter of
        Just r -> r ^. status `shouldBeM` Just Cancelled
        Nothing -> liftIO $ expectationFailure "expected the run row to still exist"

    it "finds claimed servers whose deployment never became ready" $ do
      build <- testBuild identity
      unready <- addTestServer (configurationBuildId .~ (build ^. id))
      now <- liftIO getCurrentTime
      _ready <- addTestServer ((configurationBuildId .~ (build ^. id)) . (readyAt ?~ now))
      DB.getUnreadyServers `shouldReturnM` [unready]

  let wrap test = do
        socketPath <- getEnv "TPG_SOCK"
        user <- getEnv "TPG_USER"
        withEnvironment [("TPG_SOCK", socketPath), ("TPG_USER", user)] $ do
          hSilence [stderr] test

  describe "keepUnverifiedFods" $ inM $ beforeM_ truncateDBM $ do
    it "removes verified FODs from the input list" $ do
      let verifiedDrvPath = DrvPath (StorePath (StoreHash "hash1") "verified")
          unverifiedDrvPath = DrvPath (StorePath (StoreHash "hash2") "unverified")
      DB.addVerifiedFod verifiedDrvPath (StorePath (StoreHash "hash3") "foo")
      DB.keepUnverifiedFods (Set.fromList [(verifiedDrvPath, ()), (unverifiedDrvPath, ())])
        `shouldReturnM` Set.fromList [(unverifiedDrvPath, ())]

  describe "getDBConnection" $ around_ wrap $ do
    let correctPassword = "garnix"
    let testConnection c = do
          i <- PSQL.pgQuery c [pgSQL| SELECT 1 |]
          i `shouldBe` [Just (1 :: Int32)]

    it "connects with the correct password" $ do
      c <- DB.getDBConnection [correctPassword]
      testConnection c

    it "tries multiple passwords" $ do
      c <- DB.getDBConnection ["foo", correctPassword]
      testConnection c

    it "fails with wrong passwords" $ do
      DB.getDBConnection ["foo", "bar"] `shouldThrow` (\(e :: PGError) -> "password authentication failed" `isInfixOf` cs (show e))
      pure ()
