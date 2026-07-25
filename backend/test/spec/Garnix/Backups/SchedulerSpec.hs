module Garnix.Backups.SchedulerSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as T
import Garnix.Backups
import Garnix.Backups.Scheduler (schedulerPass)
import Garnix.DB.Backups qualified as DB
import Garnix.Monad
import Garnix.Prelude
import Garnix.TestHelpers (addTestServer, testBuild, truncateDBM)
import Garnix.TestHelpers.Monad (beforeM_, inM, shouldBeM)
import Garnix.Types
import Garnix.YamlConfig (BackupSchedule (..), BackupSection (..))
import System.Directory (getFileSize)
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
  describe "isDue" $ do
    it "is due when there is no previous success" $ do
      now <- getCurrentTime
      isDue now testBackupSection Nothing `shouldBe` True

    it "is due when the last success is older than the schedule" $ do
      now <- getCurrentTime
      isDue now testBackupSection (Just (addUTCTime (-(25 * 3600)) now)) `shouldBe` True

    it "is not due when the last success is fresh" $ do
      now <- getCurrentTime
      isDue now testBackupSection (Just (addUTCTime (-3600) now)) `shouldBe` False

  describe "decodeBackupTargets" $ do
    it "decodes a valid jsonb payload and drops garbage" $ do
      let sectionText = cs (Aeson.encode testBackupSection) :: Text
          valid =
            (ServerId (1 ^. from hashIdInt), "10.0.0.1", "o", "r", Just "main", "cfg", Just "app", sectionText, Nothing)
          garbage =
            (ServerId (2 ^. from hashIdInt), "10.0.0.2", "o", "r", Nothing, "cfg2", Nothing, "not json", Nothing)
          decoded = decodeBackupTargets [valid, garbage]
      map (_backupTargetServerId . fst) decoded `shouldBe` [ServerId (1 ^. from hashIdInt)]
      map (_backupSectionPaths . _backupTargetSection . fst) decoded `shouldBe` [["/var/lib/app"]]

  describe "scheduler pass" $ inM $ beforeM_ truncateDBM $ do
    it "runs due targets and records a failed row when the guest is unreachable" $ do
      now <- liftIO getCurrentTime
      build <-
        testBuild
          $ (repoUser .~ "o")
          . (repoName .~ "r")
          . (branch ?~ "main")
          . (package .~ "cfg")
      server <-
        addTestServer
          ( \s ->
              s
                & configurationBuildId
                .~ (build ^. id)
                & readyAt
                ?~ now
                & ipv4Addr
                .~ "127.0.0.1:1"
          )
      DB.setServerBackups (server ^. id) (Just testBackupSection)
      putsRef <- liftIO $ newIORef (Map.empty :: Map Text Integer)
      let store =
            BackupStore
              { _backupStorePutFile = \key path -> liftIO $ do
                  size <- getFileSize path
                  modifyIORef' putsRef (Map.insert key size),
                _backupStoreGetFile = \key _ -> throw $ OtherError $ "getFile: no such object " <> key,
                _backupStoreDeleteObject = \_ -> pure (),
                _backupStorePresignGet = \key -> pure key,
                _backupStoreMaxSize = 4294967296
              }
      local (#backupStore ?~ store) schedulerPass
      rows <- DB.getBackupsForRepo "o" "r"
      map DB._backupRowStatus rows `shouldBeM` ["failed"]
      map DB._backupRowKind rows `shouldBeM` ["scheduled"]
      let mErr = case rows of
            [row] -> DB._backupRowError row
            _ -> Nothing
      maybe False (\e -> "ssh" `T.isInfixOf` e || "exit" `T.isInfixOf` e) mErr `shouldBeM` True
      puts <- liftIO $ readIORef putsRef
      Map.null puts `shouldBeM` True
