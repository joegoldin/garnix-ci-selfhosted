module Garnix.DB.BackupsSpec (spec) where

import Database.PostgreSQL.Typed (pgSQL)
import Garnix.DB qualified as GarnixDB
import Garnix.DB.Backups
import Garnix.Prelude
import Garnix.TestHelpers (addTestServer, testBuild, truncateDBM)
import Garnix.TestHelpers.Monad (beforeM_, inM, shouldBeM, shouldReturnM)
import Garnix.Types
import Garnix.YamlConfig (BackupSchedule (..), BackupSection (..))
import Test.Hspec

-- | A backup section with one path and a daily schedule, no hooks.
testBackupSection :: BackupSection
testBackupSection =
  BackupSection
    { _backupSectionPaths = ["/var/lib/app"],
      _backupSectionSchedule = BackupSchedule "daily" 24,
      _backupSectionPreBackupCommand = Nothing,
      _backupSectionPostBackupCommand = Nothing,
      _backupSectionPreRestoreCommand = Nothing,
      _backupSectionPostRestoreCommand = Nothing
    }

spec :: Spec
spec = do
  describe "Garnix.DB.Backups" $ inM $ beforeM_ truncateDBM $ do
    it "insert + finalize success round-trips" $ do
      someTime <- liftIO getCurrentTime
      build <- testBuild identity
      server <- addTestServer (\s -> s & configurationBuildId .~ (build ^. id) & readyAt ?~ someTime)
      bid <- insertRunningBackup (server ^. id) "o" "r" (Just "main") "nixosConfigurations.app" (Just "app") "manual"
      upsertBackupObject "hash1" 123
      finalizeBackupSuccess bid "hash1" 123
      Just row <- getBackupRow bid
      _backupRowStatus row `shouldBeM` "success"
      _backupRowObjectHash row `shouldBeM` Just "hash1"

    it "backup rows survive server deletion (server_id nulls out)" $ do
      build <- testBuild identity
      server <- addTestServer (configurationBuildId .~ (build ^. id))
      bid <- insertRunningBackup (server ^. id) "o" "r" Nothing "cfg" Nothing "manual"
      upsertBackupObject "hash2" 456
      finalizeBackupSuccess bid "hash2" 456
      void $ GarnixDB.pgExec [pgSQL| DELETE FROM servers WHERE id = ${server ^. id} |]
      Just row <- getBackupRow bid
      _backupRowServerId row `shouldBeM` Nothing
      _backupRowStatus row `shouldBeM` "success"

    it "hasRunningBackup sees running rows only" $ do
      build <- testBuild identity
      server <- addTestServer (configurationBuildId .~ (build ^. id))
      hasRunningBackup (server ^. id) `shouldReturnM` False
      bid <- insertRunningBackup (server ^. id) "o" "r" Nothing "cfg" Nothing "manual"
      hasRunningBackup (server ^. id) `shouldReturnM` True
      upsertBackupObject "hash3" 1
      finalizeBackupSuccess bid "hash3" 1
      hasRunningBackup (server ^. id) `shouldReturnM` False

    it "reaper honors retention, keep-latest default ON, and locks" $ do
      setDefaultBackupSettings 0 True
      build <- testBuild identity
      server <- addTestServer (configurationBuildId .~ (build ^. id))
      let mkSuccess h = do
            bid <- insertRunningBackup (server ^. id) "o" "r" Nothing "cfg" Nothing "manual"
            upsertBackupObject h 1
            finalizeBackupSuccess bid h 1
            pure bid
      _b1 <- mkSuccess "reaper-h1"
      b2 <- mkSuccess "reaper-h2"
      b3 <- mkSuccess "reaper-h3"
      -- lock the middle backup: it must survive regardless of keep-latest.
      setBackupLocked b2 True
      reapExpiredBackupRows `shouldReturnM` 1
      remaining1 <- getBackupsForServerConfig "o" "r" "cfg"
      sort (map _backupRowId remaining1) `shouldBeM` sort [b2, b3]
      setDefaultBackupSettings 0 False
      reapExpiredBackupRows `shouldReturnM` 1
      remaining2 <- getBackupsForServerConfig "o" "r" "cfg"
      map _backupRowId remaining2 `shouldBeM` [b2]
      setDefaultBackupSettings 30 True

    it "per-repo override beats the default" $ do
      setDefaultBackupSettings 0 False
      setRepoBackupSettings "o" "r" (Just 3650) Nothing
      build <- testBuild identity
      server <- addTestServer (configurationBuildId .~ (build ^. id))
      bKept <- insertRunningBackup (server ^. id) "o" "r" Nothing "cfg" Nothing "manual"
      upsertBackupObject "override-h1" 1
      finalizeBackupSuccess bKept "override-h1" 1
      bReaped <- insertRunningBackup (server ^. id) "other" "repo" Nothing "cfg" Nothing "manual"
      upsertBackupObject "override-h2" 1
      finalizeBackupSuccess bReaped "override-h2" 1
      reapExpiredBackupRows `shouldReturnM` 1
      rowsKept <- getBackupsForServerConfig "o" "r" "cfg"
      map _backupRowId rowsKept `shouldBeM` [bKept]
      getBackupsForServerConfig "other" "repo" "cfg" `shouldReturnM` []
      setDefaultBackupSettings 30 True

    it "getOrphanedBackupObjects finds unreferenced objects only" $ do
      build <- testBuild identity
      server <- addTestServer (configurationBuildId .~ (build ^. id))
      bid <- insertRunningBackup (server ^. id) "o" "r" Nothing "cfg" Nothing "manual"
      upsertBackupObject "referenced" 1
      finalizeBackupSuccess bid "referenced" 1
      upsertBackupObject "orphan" 1
      getOrphanedBackupObjects `shouldReturnM` ["orphan"]
      deleteBackupObject "orphan"
      getOrphanedBackupObjects `shouldReturnM` []

    it "failStaleRunningBackups only touches rows older than 2h" $ do
      build <- testBuild identity
      server <- addTestServer (configurationBuildId .~ (build ^. id))
      staleId <- insertRunningBackup (server ^. id) "o" "r" Nothing "cfg" Nothing "manual"
      void $ GarnixDB.pgExec [pgSQL| UPDATE backups SET started_at = now() - interval '3 hours' WHERE id = ${staleId} |]
      freshId <- insertRunningBackup (server ^. id) "o" "r" Nothing "cfg" Nothing "manual"
      failStaleRunningBackups `shouldReturnM` 1
      Just staleRow <- getBackupRow staleId
      _backupRowStatus staleRow `shouldBeM` "failed"
      _backupRowError staleRow `shouldBeM` Just "orphaned by restart or crash"
      Just freshRow <- getBackupRow freshId
      _backupRowStatus freshRow `shouldBeM` "running"

    it "getLiveBackupTargets returns live servers with backups config and last success" $ do
      someTime <- liftIO getCurrentTime
      build <- testBuild $ (repoUser .~ "o") . (repoName .~ "r") . (package .~ "cfg") . (persistenceName ?~ "app")
      server <- addTestServer (\s -> s & configurationBuildId .~ (build ^. id) & readyAt ?~ someTime)
      setServerBackups (server ^. id) (Just testBackupSection)

      targets1 <- getLiveBackupTargets
      let lastSuccesses1 = map (\(_, _, _, _, _, _, _, _, lastSuccess) -> lastSuccess) targets1
      map (\(sid, _, _, _, _, _, _, _, _) -> sid) targets1 `shouldBeM` [server ^. id]
      lastSuccesses1 `shouldBeM` [Nothing]

      bid <- insertRunningBackup (server ^. id) "o" "r" Nothing "cfg" (Just "app") "manual"
      upsertBackupObject "live-h1" 1
      finalizeBackupSuccess bid "live-h1" 1

      targets2 <- getLiveBackupTargets
      let lastSuccesses2 = map (\(_, _, _, _, _, _, _, _, lastSuccess) -> isJust lastSuccess) targets2
      lastSuccesses2 `shouldBeM` [True]

      -- an ended server disappears even though its backups config is set.
      deadServer <- addTestServer (\s -> s & configurationBuildId .~ (build ^. id) & readyAt ?~ someTime & endedAt ?~ someTime)
      setServerBackups (deadServer ^. id) (Just testBackupSection)
      targets3 <- getLiveBackupTargets
      length targets3 `shouldBeM` 1

    it "setServerBackups/getServerBackups round-trip the section" $ do
      build <- testBuild identity
      server <- addTestServer (configurationBuildId .~ (build ^. id))
      getServerBackups (server ^. id) `shouldReturnM` Nothing
      setServerBackups (server ^. id) (Just testBackupSection)
      getServerBackups (server ^. id) `shouldReturnM` Just testBackupSection
      setServerBackups (server ^. id) Nothing
      getServerBackups (server ^. id) `shouldReturnM` Nothing

    it "restore rows insert and finalize" $ do
      build <- testBuild identity
      server <- addTestServer (configurationBuildId .~ (build ^. id))
      bid <- insertRunningBackup (server ^. id) "o" "r" Nothing "cfg" Nothing "manual"
      upsertBackupObject "restore-h1" 1
      finalizeBackupSuccess bid "restore-h1" 1

      rid <- insertRunningRestore bid (server ^. id) "joe"
      restoresRunning <- getRestoresForServerConfig "o" "r" "cfg"
      map (\(rowId, backupId, status', errorField, initiatedBy, _, finishedAt) -> (rowId, backupId, status', errorField, initiatedBy, finishedAt)) restoresRunning
        `shouldBeM` [(rid, bid, "running", Nothing, "joe", Nothing)]

      finalizeRestoreSuccess rid
      rid2 <- insertRunningRestore bid (server ^. id) "joe"
      finalizeRestoreFailure rid2 "boom"

      restoresDone <- getRestoresForServerConfig "o" "r" "cfg"
      sort (map (\(_, _, status', errorField, _, _, _) -> (status', errorField)) restoresDone)
        `shouldBeM` sort [("success", Nothing), ("failed", Just "boom")]
