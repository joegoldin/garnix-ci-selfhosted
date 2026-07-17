module Garnix.DB.ArtifactsSpec (spec) where

import Database.PostgreSQL.Typed (pgSQL)
import Garnix.DB qualified as GarnixDB
import Garnix.DB.Artifacts qualified as DB
import Garnix.Monad (ArtifactBucket (..))
import Garnix.Prelude
import Garnix.TestHelpers (testBuild, truncateDBM)
import Garnix.TestHelpers.Monad (beforeM_, inM, shouldBeM, shouldReturnM)
import Garnix.Types
import Test.Hspec

spec :: Spec
spec = do
  describe "Garnix.DB.Artifacts" $ inM $ beforeM_ truncateDBM $ do
    it "upserts and fetches an artifact row" $ do
      build <- testBuild $ (repoUser .~ "o") . (repoName .~ "r") . (branch ?~ "main") . (package .~ "pkg")
      DB.upsertArtifact build "claude-skills" "hash1" ArtifactPublic "published"
      rows <- DB.getArtifactsForBuild (build ^. id)
      map DB._artifactRowName rows `shouldBeM` ["claude-skills"]
      -- upsert overwrites, not duplicates:
      DB.upsertArtifact build "claude-skills" "hash2" ArtifactPublic "published"
      rows2 <- DB.getArtifactsForBuild (build ^. id)
      map DB._artifactRowStoreHash rows2 `shouldBeM` ["hash2"]
      byName <- DB.getArtifactByBuildAndName (build ^. id) "claude-skills"
      (DB._artifactRowStoreHash <$> byName) `shouldBeM` Just "hash2"
      missing <- DB.getArtifactByBuildAndName (build ^. id) "nope"
      (DB._artifactRowStoreHash <$> missing) `shouldBeM` Nothing
      forM_ rows2 $ \row -> DB.deleteArtifactRow (DB._artifactRowId row)
      DB.getArtifactsForBuild (build ^. id) `shouldReturnM` []

    it "latest returns the newest published row per branch+name" $ do
      b1 <- testBuild $ (repoUser .~ "o") . (repoName .~ "r") . (branch ?~ "main")
      b2 <- testBuild $ (repoUser .~ "o") . (repoName .~ "r") . (branch ?~ "main")
      DB.upsertArtifact b1 "a" "h1" ArtifactPublic "published"
      DB.upsertArtifact b2 "a" "h2" ArtifactPublic "published"
      row <- DB.getLatestArtifact "o" "r" "main" "a"
      (DB._artifactRowStoreHash <$> row) `shouldBeM` Just "h2"

    it "locking flips all of a build's rows" $ do
      b <- testBuild identity
      DB.upsertArtifact b "a" "h" ArtifactPrivate "published"
      DB.setBuildArtifactsLocked (b ^. id) True
      rows <- DB.getArtifactsForBuild (b ^. id)
      map DB._artifactRowLocked rows `shouldBeM` [True]
      locked <- DB.getLockedArtifactBuilds
      map DB._artifactRowBuildId locked `shouldBeM` [b ^. id]
      DB.setBuildArtifactsLocked (b ^. id) False
      DB.getLockedArtifactBuilds `shouldReturnM` []

    it "object dedupe bookkeeping" $ do
      DB.artifactObjectExists "h" ArtifactPublic `shouldReturnM` False
      DB.insertArtifactObject "h" ArtifactPublic 123 4
      DB.artifactObjectExists "h" ArtifactPublic `shouldReturnM` True
      -- the same hash in the other bucket is a different object:
      DB.artifactObjectExists "h" ArtifactPrivate `shouldReturnM` False

    it "repo listing filters by branch" $ do
      b1 <- testBuild (branch ?~ "main")
      b2 <- testBuild (branch ?~ "dev")
      DB.upsertArtifact b1 "a" "h1" ArtifactPublic "published"
      DB.upsertArtifact b2 "a" "h2" ArtifactPublic "published"
      allRows <- DB.getArtifactsForRepo "test-owner" "test-repo" Nothing
      length allRows `shouldBeM` 2
      mainRows <- DB.getArtifactsForRepo "test-owner" "test-repo" (Just "main")
      map DB._artifactRowStoreHash mainRows `shouldBeM` ["h1"]

    it "dto rows join object size and file count" $ do
      b <- testBuild identity
      DB.upsertArtifact b "with-object" "h1" ArtifactPublic "published"
      DB.insertArtifactObject "h1" ArtifactPublic 123 4
      DB.upsertArtifact b "without-object" "" ArtifactPublic "failed"
      dtos <- DB.getArtifactDtosForBuild (b ^. id)
      sort (map (\dto -> (DB._artifactDtoRowName dto, DB._artifactDtoRowTotalSize dto, DB._artifactDtoRowFileCount dto)) dtos)
        `shouldBeM` [("with-object", 123, 4), ("without-object", 0, 0)]

    it "storage usage dedupes shared objects per repo" $ do
      b1 <- testBuild identity
      b2 <- testBuild identity
      DB.upsertArtifact b1 "a" "h" ArtifactPublic "published"
      DB.upsertArtifact b2 "a" "h" ArtifactPublic "published"
      DB.insertArtifactObject "h" ArtifactPublic 100 1
      DB.getArtifactStorageUsage `shouldReturnM` [("test-owner", "test-repo", 100)]

    it "orphaned objects are listed and deletable" $ do
      b <- testBuild identity
      DB.upsertArtifact b "a" "referenced" ArtifactPublic "published"
      DB.insertArtifactObject "referenced" ArtifactPublic 1 1
      DB.insertArtifactObject "orphan" ArtifactPublic 1 1
      DB.getOrphanedArtifactObjects `shouldReturnM` [("orphan", ArtifactPublic)]
      DB.deleteArtifactObject "orphan" ArtifactPublic
      DB.getOrphanedArtifactObjects `shouldReturnM` []

    it "settings roundtrip with repo overrides" $ do
      DB.setDefaultArtifactSettings 30 False
      DB.getArtifactSettings `shouldReturnM` (30, False)
      DB.setDefaultArtifactSettings 7 True
      DB.getArtifactSettings `shouldReturnM` (7, True)
      DB.getArtifactRepoOverrides `shouldReturnM` []
      DB.setRepoArtifactSettings "o" "r" (Just 90) Nothing
      DB.getArtifactRepoOverrides `shouldReturnM` [("o", "r", Just 90, Nothing)]
      DB.deleteRepoArtifactSettings "o" "r"
      DB.getArtifactRepoOverrides `shouldReturnM` []
      DB.setDefaultArtifactSettings 30 False

    it "reaps expired unlocked rows and prunes old failed rows" $ do
      DB.setDefaultArtifactSettings 30 False
      b1 <- testBuild identity
      b2 <- testBuild identity
      b3 <- testBuild identity
      DB.upsertArtifact b1 "old" "h1" ArtifactPublic "published"
      DB.upsertArtifact b2 "locked" "h2" ArtifactPublic "published"
      DB.upsertArtifact b3 "failed" "h3" ArtifactPublic "failed"
      DB.setBuildArtifactsLocked (b2 ^. id) True
      void $ GarnixDB.pgExec [pgSQL| UPDATE artifacts SET created_at = now() - interval '40 days' |]
      b4 <- testBuild identity
      DB.upsertArtifact b4 "fresh" "h4" ArtifactPublic "published"
      DB.reapExpiredArtifactRows `shouldReturnM` 1
      DB.pruneFailedArtifactRows `shouldReturnM` 1
      rows <- DB.getArtifactsForRepo "test-owner" "test-repo" Nothing
      sort (map DB._artifactRowName rows) `shouldBeM` ["fresh", "locked"]

    it "keep-latest protects the newest row per repo/branch/name" $ do
      DB.setDefaultArtifactSettings 30 True
      b1 <- testBuild identity
      b2 <- testBuild identity
      DB.upsertArtifact b1 "a" "h1" ArtifactPublic "published"
      DB.upsertArtifact b2 "a" "h2" ArtifactPublic "published"
      void $ GarnixDB.pgExec [pgSQL| UPDATE artifacts SET created_at = now() - interval '40 days' |]
      DB.reapExpiredArtifactRows `shouldReturnM` 1
      remaining <- DB.getArtifactsForRepo "test-owner" "test-repo" Nothing
      map DB._artifactRowStoreHash remaining `shouldBeM` ["h2"]
      DB.setDefaultArtifactSettings 30 False
