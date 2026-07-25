module Garnix.API.BackupsSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Garnix.API.Backups
import Garnix.AccessToken (generateToken)
import Garnix.AccessToken.Types (AccessTokenScopes (..), getAccessTokenText)
import Garnix.DB qualified as DB
import Garnix.DB.Backups qualified as Backups
import Garnix.Monad
import Garnix.Prelude
import Garnix.TestHelpers (addTestServer, testBuild, truncateDBM)
import Garnix.TestHelpers.Monad (beforeM_, inM, shouldBeM, shouldReturnM, shouldThrowM)
import Garnix.Types
import Garnix.YamlConfig (BackupSchedule (..), BackupSection (..))
import Servant.Auth.Server (AuthResult (..))
import Test.Hspec
import "base64-bytestring" Data.ByteString.Base64 qualified as Base64

spec :: Spec
spec = do
  describe "Garnix.API.Backups" $ inM $ beforeM_ truncateDBM $ do
    it "404s everything when no backup store is configured" $ do
      server <- testServer
      backupId <- successfulBackup server "h1"
      admin <- sessionAs "backups-admin" Admin
      _backupsAPIListRepo admin "test-owner" "test-repo" `shouldThrowM` NotFound
      _backupsAPIListServer admin (server ^. id) `shouldThrowM` NotFound
      _backupsAPIListRestores admin (server ^. id) `shouldThrowM` NotFound
      _backupsAPIDownload admin backupId `shouldThrowM` NotFound
      _backupsAPILatest admin "test-owner" "test-repo" "test-package" `shouldThrowM` NotFound
      _backupsAPIBackupNow admin (server ^. id) `shouldThrowM` NotFound
      _backupsAPIRestore admin backupId `shouldThrowM` NotFound
      _backupsAPILock admin backupId `shouldThrowM` NotFound
      _backupsAPIDelete admin backupId `shouldThrowM` NotFound

    it "rejects anonymous access even with a store (never public)" $ withStore $ do
      server <- testServer
      backupId <- successfulBackup server "h1"
      _backupsAPIListRepo anonymous "test-owner" "test-repo" `shouldThrowM` NotFound
      _backupsAPIListServer anonymous (server ^. id) `shouldThrowM` NotFound
      _backupsAPIListRestores anonymous (server ^. id) `shouldThrowM` NotFound
      _backupsAPIDownload anonymous backupId `shouldThrowM` NotFound
      _backupsAPILatest anonymous "test-owner" "test-repo" "test-package" `shouldThrowM` NotFound
      _backupsAPIBackupNow anonymous (server ^. id) `shouldThrowM` NotFound

    it "a user with repo access can list; one without gets 404" $ withStore $ do
      server <- testServer
      void $ successfulBackup server "h1"
      admin <- sessionAs "backups-admin" Admin
      repoDtos <- _backupsAPIListRepo admin "test-owner" "test-repo"
      map _backupDtoObjectHash repoDtos `shouldBeM` [Just "h1"]
      serverDtos <- _backupsAPIListServer admin (server ^. id)
      map _backupDtoStatus serverDtos `shouldBeM` ["success"]
      -- A non-admin session user is not a collaborator of the test repo, so
      -- every route is 404-shaped rather than 403.
      nonAdmin <- sessionAs "backups-user" FreeSubscription
      _backupsAPIListRepo nonAdmin "test-owner" "test-repo" `shouldThrowM` NotFound
      _backupsAPIListServer nonAdmin (server ^. id) `shouldThrowM` NotFound

    it "404s a server id that does not exist" $ withStore $ do
      admin <- sessionAs "backups-admin" Admin
      _backupsAPIListServer admin (ServerId (99999 ^. from hashIdInt)) `shouldThrowM` NotFound

    it "download 302s to a presigned URL for an accessible snapshot" $ withStore $ do
      server <- testServer
      backupId <- successfulBackup server "h1"
      admin <- sessionAs "backups-admin" Admin
      _backupsAPIDownload admin backupId
        `shouldThrowM` RedirectFound "presigned://backups/h1.tar.zst"

    it "download 404s a snapshot with no stored object" $ withStore $ do
      server <- testServer
      backupId <-
        Backups.insertRunningBackup (server ^. id) "test-owner" "test-repo" (Just "test-branch") "test-package" Nothing "manual"
      admin <- sessionAs "backups-admin" Admin
      _backupsAPIDownload admin backupId `shouldThrowM` NotFound

    it "latest.tar.zst resolves the newest successful snapshot" $ withStore $ do
      server <- testServer
      void $ successfulBackup server "old"
      void $ successfulBackup server "new"
      admin <- sessionAs "backups-admin" Admin
      _backupsAPILatest admin "test-owner" "test-repo" "test-package"
        `shouldThrowM` RedirectFound "presigned://backups/new.tar.zst"

    it "latest.tar.zst 404s when the configuration has no successful snapshot" $ withStore $ do
      void testServer
      admin <- sessionAs "backups-admin" Admin
      _backupsAPILatest admin "test-owner" "test-repo" "no-such-config" `shouldThrowM` NotFound

    it "lock/unlock require admin and flip the row" $ withStore $ do
      server <- testServer
      backupId <- successfulBackup server "h1"
      nonAdmin <- sessionAs "backups-user" FreeSubscription
      _backupsAPILock anonymous backupId `shouldThrowM` Unauthorized
      _backupsAPILock nonAdmin backupId `shouldThrowM` Unauthorized
      admin <- sessionAs "backups-admin" Admin
      void $ _backupsAPILock admin backupId
      lockedRow <- Backups.getBackupRow backupId
      (Backups._backupRowLocked <$> lockedRow) `shouldBeM` Just True
      void $ _backupsAPIUnlock admin backupId
      unlockedRow <- Backups.getBackupRow backupId
      (Backups._backupRowLocked <$> unlockedRow) `shouldBeM` Just False

    it "delete requires admin, refuses locked rows, and removes the row" $ withStore $ do
      server <- testServer
      backupId <- successfulBackup server "h1"
      _backupsAPIDelete anonymous backupId `shouldThrowM` Unauthorized
      admin <- sessionAs "backups-admin" Admin
      void $ _backupsAPILock admin backupId
      _backupsAPIDelete admin backupId `shouldThrowM` BadRequest "Backup is locked"
      void $ _backupsAPIUnlock admin backupId
      void $ _backupsAPIDelete admin backupId
      Backups.getBackupRow backupId `shouldReturnM` Nothing

    it "backup-now refuses when a backup is already running" $ withStore $ do
      server <- testServer
      Backups.setServerBackups (server ^. id) (Just testBackupSection)
      void $ Backups.insertRunningBackup (server ^. id) "test-owner" "test-repo" Nothing "test-package" Nothing "manual"
      admin <- sessionAs "backups-admin" Admin
      _backupsAPIBackupNow admin (server ^. id)
        `shouldThrowM` BadRequest "A backup is already running for this server"

    it "backup-now refuses a server with no backups configured" $ withStore $ do
      server <- testServer
      admin <- sessionAs "backups-admin" Admin
      _backupsAPIBackupNow admin (server ^. id)
        `shouldThrowM` BadRequest "Server has no backups configured"

    it "restore refuses when no live server hosts that configuration" $ withStore $ do
      server <- testServer
      backupId <- successfulBackup server "h1"
      -- The snapshot outlives its server: tear it down and the restore has no target.
      DB.deleteServerDB (server ^. id)
      admin <- sessionAs "backups-admin" Admin
      _backupsAPIRestore admin backupId
        `shouldThrowM` BadRequest "No live server to restore onto — deploy it first"

    it "restore refuses a snapshot with no stored object" $ withStore $ do
      server <- testServer
      backupId <-
        Backups.insertRunningBackup (server ^. id) "test-owner" "test-repo" Nothing "test-package" Nothing "manual"
      admin <- sessionAs "backups-admin" Admin
      _backupsAPIRestore admin backupId `shouldThrowM` NotFound

    it "serializes BackupDto with the exact snake_case keys the frontend parses" $ withStore $ do
      server <- testServer
      void $ successfulBackup server "h1"
      admin <- sessionAs "backups-admin" Admin
      dtos <- _backupsAPIListRepo admin "test-owner" "test-repo"
      dto <- case dtos of
        [dto] -> pure dto
        _ -> throw $ OtherError "expected exactly one backup dto"
      case toJSON dto of
        Aeson.Object obj -> do
          -- 'ourToJSON' omits Nothing fields, so this successful, unnamed
          -- snapshot emits neither "error" nor "persistence_name" (the
          -- frontend parses both as nullish).
          sort (map Key.toText (KeyMap.keys obj))
            `shouldBeM` sort
              [ "id",
                "server_id",
                "repo_user",
                "repo_name",
                "branch",
                "configuration",
                "object_hash",
                "status",
                "kind",
                "locked",
                "size",
                "started_at",
                "finished_at"
              ]
          -- the frontend expects the hashid string, not a number:
          KeyMap.lookup "server_id" obj
            `shouldBeM` Just (Aeson.String (getHashId (getServerId (server ^. id))))
        _ -> throw $ OtherError "BackupDto should serialize to an object"

    it "accepts a basic-auth access token with the api scope" $ withStore $ do
      server <- testServer
      backupId <- successfulBackup server "h1"
      user <- DB.newUser (GhLogin "backups-token-admin") (Email "backups-token-admin@example.com") Admin True
      token <- generateToken (user ^. id) "backups-token" (AccessTokenScopes {cache = False, api = True})
      let session = backupsAPI Indefinite (Just (basicAuthHeader "backups-token-admin" (getAccessTokenText token)))
      _backupsAPIDownload session backupId
        `shouldThrowM` RedirectFound "presigned://backups/h1.tar.zst"

    it "rejects access tokens without the api scope" $ withStore $ do
      server <- testServer
      backupId <- successfulBackup server "h1"
      user <- DB.newUser (GhLogin "backups-token-user") (Email "backups-token-user@example.com") Admin True
      token <- generateToken (user ^. id) "cache-token" (AccessTokenScopes {cache = True, api = False})
      let cacheOnly = backupsAPI Indefinite (Just (basicAuthHeader "backups-token-user" (getAccessTokenText token)))
      _backupsAPIDownload cacheOnly backupId `shouldThrowM` InvalidAccessToken

-- | A live server whose build is the default test repo\/configuration.
testServer :: M ServerInfo
testServer = do
  now <- liftIO getCurrentTime
  build <- testBuild identity
  addTestServer $ \s ->
    s
      & configurationBuildId
      .~ (build ^. id)
      & readyAt
      ?~ now
      & ipv4Addr
      .~ "127.0.0.1:1"

-- | A finished, successful snapshot of 'testServer' with the given object hash.
successfulBackup :: ServerInfo -> Text -> M Int64
successfulBackup server objectHash = do
  backupId <-
    Backups.insertRunningBackup
      (server ^. id)
      "test-owner"
      "test-repo"
      (Just "test-branch")
      "test-package"
      Nothing
      "scheduled"
  Backups.upsertBackupObject objectHash 123
  Backups.finalizeBackupSuccess backupId objectHash 123
  pure backupId

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

-- | Handlers acting as an unauthenticated caller.
anonymous :: BackupsAPI (AsServerT M)
anonymous = backupsAPI Indefinite Nothing

-- | Handlers acting as a (fresh) session user with the given subscription.
sessionAs :: GhLogin -> SubscriptionType -> M (BackupsAPI (AsServerT M))
sessionAs login sub = do
  user <- DB.newUser login (Email $ getGhLogin login <> "@example.com") sub True
  pure $ backupsAPI (Authenticated (ApiSession user)) Nothing

basicAuthHeader :: Text -> Text -> Text
basicAuthHeader login password = "Basic " <> cs (Base64.encode (cs (login <> ":" <> password)))

-- | An in-memory 'BackupStore' good enough for the API: presigned URLs are
-- @presigned://\<key>@; capture\/restore IO is never exercised here.
withStore :: M a -> M a
withStore = local (#backupStore ?~ testBackupStore)

testBackupStore :: BackupStore
testBackupStore =
  BackupStore
    { _backupStorePutFile = \_ _ -> notNeeded,
      _backupStoreGetFile = \_ _ -> notNeeded,
      _backupStoreDeleteObject = const notNeeded,
      _backupStorePresignGet = \key -> pure $ "presigned://" <> key,
      _backupStoreMaxSize = 4294967296
    }
  where
    notNeeded :: M a
    notNeeded = throw $ OtherError "testBackupStore: not needed by the API spec"
