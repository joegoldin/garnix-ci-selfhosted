module Garnix.Artifacts.ReaperSpec (spec) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Database.PostgreSQL.Typed (pgSQL)
import Garnix.Artifacts.Reaper qualified as Reaper
import Garnix.DB qualified as GarnixDB
import Garnix.DB.Artifacts qualified as DB
import Garnix.Monad (ArtifactBucket (..), ArtifactStore (..))
import Garnix.Prelude
import Garnix.TestHelpers (testBuild, truncateDBM)
import Garnix.TestHelpers.Monad (beforeM_, inM, shouldBeM, shouldReturnM)
import Garnix.Types
import Test.Hspec

-- server_settings is not truncated by 'truncateDBM', so every test pins the
-- global settings it needs up front, and tests that leave them non-default
-- restore (30, False) at the end.
spec :: Spec
spec = do
  describe "Garnix.Artifacts.Reaper" $ inM $ beforeM_ truncateDBM $ do
    it "reaps expired unlocked rows and keeps fresh ones" $ do
      DB.setDefaultArtifactSettings 30 False
      b <- testBuild identity
      DB.upsertArtifact b "old" "h-old" ArtifactPublic "published"
      DB.upsertArtifact b "fresh" "h-fresh" ArtifactPublic "published"
      void $ GarnixDB.pgExec [pgSQL| UPDATE artifacts SET created_at = now() - interval '40 days' WHERE name = 'old' |]
      Reaper.reapOnce
      rows <- DB.getArtifactsForBuild (b ^. id)
      map DB._artifactRowName rows `shouldBeM` ["fresh"]

    it "honors per-repo retention overrides" $ do
      DB.setDefaultArtifactSettings 30 False
      overridden <- testBuild identity
      other <- testBuild $ (repoUser .~ "other-owner") . (repoName .~ "other-repo")
      DB.upsertArtifact overridden "a" "h-overridden" ArtifactPublic "published"
      DB.upsertArtifact other "a" "h-other" ArtifactPublic "published"
      DB.setRepoArtifactSettings "test-owner" "test-repo" (Just 90) Nothing
      void $ GarnixDB.pgExec [pgSQL| UPDATE artifacts SET created_at = now() - interval '40 days' |]
      Reaper.reapOnce
      -- 40 days is past the 30-day default (other repo reaped) but within the
      -- overridden repo's 90 days:
      DB.getArtifactsForRepo "other-owner" "other-repo" Nothing `shouldReturnM` []
      kept <- DB.getArtifactsForRepo "test-owner" "test-repo" Nothing
      map DB._artifactRowStoreHash kept `shouldBeM` ["h-overridden"]
      -- past the override, the row goes too:
      void $ GarnixDB.pgExec [pgSQL| UPDATE artifacts SET created_at = now() - interval '100 days' |]
      Reaper.reapOnce
      DB.getArtifactsForRepo "test-owner" "test-repo" Nothing `shouldReturnM` []

    it "never reaps locked rows" $ do
      DB.setDefaultArtifactSettings 30 False
      b <- testBuild identity
      DB.upsertArtifact b "a" "h" ArtifactPublic "published"
      DB.setBuildArtifactsLocked (b ^. id) True
      void $ GarnixDB.pgExec [pgSQL| UPDATE artifacts SET created_at = now() - interval '400 days' |]
      Reaper.reapOnce
      rows <- DB.getArtifactsForBuild (b ^. id)
      map DB._artifactRowName rows `shouldBeM` ["a"]

    it "keep-latest (global) protects the newest row per repo/branch/name" $ do
      DB.setDefaultArtifactSettings 30 True
      b1 <- testBuild identity
      b2 <- testBuild identity
      DB.upsertArtifact b1 "a" "h1" ArtifactPublic "published"
      DB.upsertArtifact b2 "a" "h2" ArtifactPublic "published"
      void $ GarnixDB.pgExec [pgSQL| UPDATE artifacts SET created_at = now() - interval '50 days' WHERE store_hash = 'h1' |]
      void $ GarnixDB.pgExec [pgSQL| UPDATE artifacts SET created_at = now() - interval '40 days' WHERE store_hash = 'h2' |]
      Reaper.reapOnce
      -- both rows are expired, but the newest per (repo, branch, name)
      -- survives; the older one is still reaped:
      remaining <- DB.getArtifactsForRepo "test-owner" "test-repo" Nothing
      map DB._artifactRowStoreHash remaining `shouldBeM` ["h2"]
      DB.setDefaultArtifactSettings 30 False

    it "repo keep-latest override beats the global setting" $ do
      DB.setDefaultArtifactSettings 30 True
      DB.setRepoArtifactSettings "test-owner" "test-repo" Nothing (Just False)
      b1 <- testBuild identity
      b2 <- testBuild identity
      DB.upsertArtifact b1 "a" "h1" ArtifactPublic "published"
      DB.upsertArtifact b2 "a" "h2" ArtifactPublic "published"
      void $ GarnixDB.pgExec [pgSQL| UPDATE artifacts SET created_at = now() - interval '40 days' |]
      Reaper.reapOnce
      -- keep-latest is off for this repo, so even the newest expired row goes:
      DB.getArtifactsForRepo "test-owner" "test-repo" Nothing `shouldReturnM` []
      DB.setDefaultArtifactSettings 30 False

    it "prunes failed rows older than 7 days" $ do
      DB.setDefaultArtifactSettings 30 False
      b1 <- testBuild identity
      b2 <- testBuild identity
      DB.upsertArtifact b1 "old-failed" "" ArtifactPublic "failed"
      DB.upsertArtifact b2 "new-failed" "" ArtifactPublic "failed"
      void $ GarnixDB.pgExec [pgSQL| UPDATE artifacts SET created_at = now() - interval '8 days' WHERE name = 'old-failed' |]
      Reaper.reapOnce
      rows <- DB.getArtifactsForRepo "test-owner" "test-repo" Nothing
      map DB._artifactRowName rows `shouldBeM` ["new-failed"]

    it "GCs objects only when no row references them" $ do
      DB.setDefaultArtifactSettings 30 False
      b1 <- testBuild identity
      b2 <- testBuild identity
      DB.upsertArtifact b1 "a" "shared" ArtifactPublic "published"
      DB.upsertArtifact b2 "b" "shared" ArtifactPublic "published"
      DB.insertArtifactObject "shared" ArtifactPublic 100 2
      DB.insertArtifactObject "orphan" ArtifactPrivate 50 1
      -- without a configured store, GC is skipped entirely:
      Reaper.reapOnce
      DB.artifactObjectExists "orphan" ArtifactPrivate `shouldReturnM` True
      deletedPrefixes <- liftIO $ newIORef ([] :: [(ArtifactBucket, Text)])
      let store =
            ArtifactStore
              { _artifactStorePutFile = \_ _ _ -> error "putFile: unused in test",
                _artifactStorePutBytes = \_ _ _ -> error "putBytes: unused in test",
                _artifactStoreDeletePrefix = \bucket prefix ->
                  liftIO $ modifyIORef' deletedPrefixes ((bucket, prefix) :),
                _artifactStorePresignGet = \_ _ -> error "presignGet: unused in test",
                _artifactStorePublicUrl = \_ -> error "publicUrl: unused in test"
              }
      local (#artifactStore ?~ store) Reaper.reapOnce
      -- only the orphan's prefix is deleted from storage...
      liftIO (readIORef deletedPrefixes) `shouldReturnM` [(ArtifactPrivate, "artifacts/orphan/")]
      -- ...and only its bookkeeping row is dropped:
      DB.artifactObjectExists "orphan" ArtifactPrivate `shouldReturnM` False
      DB.artifactObjectExists "shared" ArtifactPublic `shouldReturnM` True
      DB.getOrphanedArtifactObjects `shouldReturnM` []
