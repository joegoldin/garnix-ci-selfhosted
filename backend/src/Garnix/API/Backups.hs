-- | Management API for scheduled server backups (garnix.yaml
-- @servers[].backups:@): listings for the Servers-page modal, presigned
-- downloads, manual capture\/restore triggers, and admin-only
-- lock\/unlock\/delete.
--
-- Auth: NEVER anonymous — server backups are always sensitive (unlike
-- artifacts, which have a public bucket). Every route needs a session user or
-- a basic-auth access token (@api@ scope) with access to the repo; failures
-- are 404-shaped to avoid existence leaks. The whole API 404s when no
-- 'BackupStore' is configured.
module Garnix.API.Backups
  ( BackupsAPI (..),
    backupsAPI,
    BackupDto (..),
    RestoreDto (..),
  )
where

import Garnix.API.Admin (requireAdmin)
import Garnix.API.Artifacts (Get302, resolveDownloadUser)
import Garnix.Access (hasAccessToRepo)
import Garnix.Backups (BackupTarget (..), runServerBackup, runServerRestore, backupObjectKey)
import Garnix.DB.Backups qualified as DB
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import Garnix.YamlConfig (BackupSection)
import Servant.Auth.Server (AuthResult (..))

data BackupsAPI route = BackupsAPI
  { _backupsAPIListRepo ::
      route
        :- "repo"
          :> Capture "owner" GhRepoOwner
          :> Capture "repo" GhRepoName
          :> Get '[JSON] [BackupDto],
    _backupsAPIListServer ::
      route
        :- "server"
          :> Capture "serverId" ServerId
          :> Get '[JSON] [BackupDto],
    _backupsAPIListRestores ::
      route
        :- "server"
          :> Capture "serverId" ServerId
          :> "restores"
          :> Get '[JSON] [RestoreDto],
    _backupsAPIDownload ::
      route
        :- Capture "backupId" Int64
          :> "download"
          :> Get302,
    _backupsAPILatest ::
      route
        :- "repo"
          :> Capture "owner" GhRepoOwner
          :> Capture "repo" GhRepoName
          :> Capture "configuration" Text
          :> "latest.tar.zst"
          :> Get302,
    _backupsAPIBackupNow ::
      route
        :- "server"
          :> Capture "serverId" ServerId
          :> "backup-now"
          :> Post '[JSON] NoContent,
    _backupsAPIRestore ::
      route
        :- Capture "backupId" Int64
          :> "restore"
          :> Post '[JSON] NoContent,
    _backupsAPILock ::
      route
        :- Capture "backupId" Int64
          :> "lock"
          :> Post '[JSON] NoContent,
    _backupsAPIUnlock ::
      route
        :- Capture "backupId" Int64
          :> "lock"
          :> Delete '[JSON] NoContent,
    _backupsAPIDelete ::
      route
        :- Capture "backupId" Int64
          :> Delete '[JSON] NoContent
  }
  deriving (Generic)

-- | A backup row for the web UI; mirrors 'DB.BackupRow' 1:1. Serializes with
-- snake_case keys via 'ourToJSON'; @server_id@ serializes as the hashid
-- string (like every other server id in the API).
data BackupDto = BackupDto
  { _backupDtoId :: Int64,
    _backupDtoServerId :: Maybe ServerId,
    _backupDtoRepoUser :: GhRepoOwner,
    _backupDtoRepoName :: GhRepoName,
    _backupDtoBranch :: Maybe Branch,
    _backupDtoConfiguration :: Text,
    _backupDtoPersistenceName :: Maybe Text,
    _backupDtoObjectHash :: Maybe Text,
    _backupDtoStatus :: Text,
    _backupDtoError :: Maybe Text,
    _backupDtoKind :: Text,
    _backupDtoLocked :: Bool,
    _backupDtoSize :: Maybe Int64,
    _backupDtoStartedAt :: UTCTime,
    _backupDtoFinishedAt :: Maybe UTCTime
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON BackupDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

-- | One restore attempt, for the modal's audit list.
data RestoreDto = RestoreDto
  { _restoreDtoId :: Int64,
    _restoreDtoBackupId :: Int64,
    _restoreDtoStatus :: Text,
    _restoreDtoError :: Maybe Text,
    _restoreDtoInitiatedBy :: Text,
    _restoreDtoStartedAt :: UTCTime,
    _restoreDtoFinishedAt :: Maybe UTCTime
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON RestoreDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

toBackupDto :: DB.BackupRow -> BackupDto
toBackupDto row =
  BackupDto
    { _backupDtoId = DB._backupRowId row,
      _backupDtoServerId = DB._backupRowServerId row,
      _backupDtoRepoUser = DB._backupRowRepoUser row,
      _backupDtoRepoName = DB._backupRowRepoName row,
      _backupDtoBranch = DB._backupRowBranch row,
      _backupDtoConfiguration = DB._backupRowConfiguration row,
      _backupDtoPersistenceName = DB._backupRowPersistenceName row,
      _backupDtoObjectHash = DB._backupRowObjectHash row,
      _backupDtoStatus = DB._backupRowStatus row,
      _backupDtoError = DB._backupRowError row,
      _backupDtoKind = DB._backupRowKind row,
      _backupDtoLocked = DB._backupRowLocked row,
      _backupDtoSize = DB._backupRowSize row,
      _backupDtoStartedAt = DB._backupRowStartedAt row,
      _backupDtoFinishedAt = DB._backupRowFinishedAt row
    }

toRestoreDto :: (Int64, Int64, Text, Maybe Text, Text, UTCTime, Maybe UTCTime) -> RestoreDto
toRestoreDto (restoreId, backupId, status', error', initiatedBy, startedAt, finishedAt) =
  RestoreDto
    { _restoreDtoId = restoreId,
      _restoreDtoBackupId = backupId,
      _restoreDtoStatus = status',
      _restoreDtoError = error',
      _restoreDtoInitiatedBy = initiatedBy,
      _restoreDtoStartedAt = startedAt,
      _restoreDtoFinishedAt = finishedAt
    }

backupsAPI :: AuthResult AuthJwtPayload -> Maybe Text -> BackupsAPI (AsServerT M)
backupsAPI auth authHeader =
  BackupsAPI
    { _backupsAPIListRepo = \owner repo -> do
        void requireBackupStore
        requireRepoAccess owner repo
        map toBackupDto <$> DB.getBackupsForRepo owner repo,
      _backupsAPIListServer = \serverId -> do
        void requireBackupStore
        (owner, repo, configuration) <- requireServerAccess serverId
        map toBackupDto <$> DB.getBackupsForServerConfig owner repo configuration,
      _backupsAPIListRestores = \serverId -> do
        void requireBackupStore
        (owner, repo, configuration) <- requireServerAccess serverId
        map toRestoreDto <$> DB.getRestoresForServerConfig owner repo configuration,
      _backupsAPIDownload = \backupId -> do
        store <- requireBackupStore
        row <- requireBackupAccess backupId
        hash <- requireObjectHash row
        url <- _backupStorePresignGet store (backupObjectKey hash)
        throw $ RedirectFound url,
      _backupsAPILatest = \owner repo configuration -> do
        store <- requireBackupStore
        requireRepoAccess owner repo
        row <-
          DB.getLatestSuccessfulBackup owner repo configuration
            >>= maybe (throw NotFound) pure
        hash <- requireObjectHash row
        url <- _backupStorePresignGet store (backupObjectKey hash)
        throw $ RedirectFound url,
      _backupsAPIBackupNow = \serverId -> do
        store <- requireBackupStore
        void $ requireServerAccess serverId
        running <- DB.hasRunningBackup serverId
        when running $ throw $ BadRequest "A backup is already running for this server"
        target <- requireBackupTarget serverId
        void $ fork $ runServerBackup store target "manual"
        pure NoContent,
      _backupsAPIRestore = \backupId -> do
        store <- requireBackupStore
        row <- requireBackupAccess backupId
        void $ requireObjectHash row
        user <- requireUser
        server <-
          DB.getLiveServerForConfig
            (DB._backupRowRepoUser row)
            (DB._backupRowRepoName row)
            (DB._backupRowConfiguration row)
            >>= maybe (throw $ BadRequest "No live server to restore onto — deploy it first") pure
        void $ fork $ runServerRestore store row server (getGhLogin (user ^. githubLogin))
        pure NoContent,
      _backupsAPILock = (`setLocked` True),
      _backupsAPIUnlock = (`setLocked` False),
      _backupsAPIDelete = \backupId -> do
        void requireBackupStore
        requireAdmin auth
        row <- DB.getBackupRow backupId >>= maybe (throw NotFound) pure
        when (DB._backupRowLocked row) $ throw $ BadRequest "Backup is locked"
        DB.deleteBackupRow backupId
        pure NoContent
    }
  where
    -- | The backups feature is off (no @S3_BACKUPS_*@ config): 404 everything.
    requireBackupStore :: M BackupStore
    requireBackupStore =
      view #backupStore >>= \case
        Just store -> pure store
        Nothing -> throw NotFound

    -- | Never anonymous: no resolvable user is a 404, same shape as no access.
    requireUser :: M User
    requireUser = resolveDownloadUser auth authHeader >>= maybe (throw NotFound) pure

    -- | 404-shaped (not 403) on missing access, to avoid existence leaks.
    requireRepoAccess :: GhRepoOwner -> GhRepoName -> M ()
    requireRepoAccess owner repo = do
      user <- requireUser
      allowed <- hasAccessToRepo (Just user) (RepoIsPublic False) owner repo
      unless allowed $ throw NotFound

    requireServerAccess :: ServerId -> M (GhRepoOwner, GhRepoName, Text)
    requireServerAccess serverId = do
      resolved <- DB.getServerRepoAndConfig serverId >>= maybe (throw NotFound) pure
      let (owner, repo, _) = resolved
      requireRepoAccess owner repo
      pure resolved

    requireBackupAccess :: Int64 -> M DB.BackupRow
    requireBackupAccess backupId = do
      row <- DB.getBackupRow backupId >>= maybe (throw NotFound) pure
      requireRepoAccess (DB._backupRowRepoUser row) (DB._backupRowRepoName row)
      pure row

    requireObjectHash :: DB.BackupRow -> M Text
    requireObjectHash row = case DB._backupRowObjectHash row of
      Nothing -> throw NotFound
      Just hash -> pure hash

    -- | Build the capture target for a manual run: the server must be live
    -- AND its deploy must have captured a @backups:@ section.
    requireBackupTarget :: ServerId -> M BackupTarget
    requireBackupTarget serverId = do
      row <-
        DB.getBackupTargetForServer serverId
          >>= maybe (throw $ BadRequest "Server has no backups configured") pure
      section <-
        DB.getServerBackups serverId
          >>= maybe (throw $ BadRequest "Server has no backups configured") pure
      pure $ toBackupTarget row section

    setLocked :: Int64 -> Bool -> M NoContent
    setLocked backupId locked = do
      void requireBackupStore
      requireAdmin auth
      void $ DB.getBackupRow backupId >>= maybe (throw NotFound) pure
      DB.setBackupLocked backupId locked
      pure NoContent

toBackupTarget ::
  (ServerId, Text, GhRepoOwner, GhRepoName, Maybe Branch, Text, Maybe Text, Text) ->
  BackupSection ->
  BackupTarget
toBackupTarget (serverId, ipv4, owner, repo, branch', configuration, persistenceName, _) section =
  BackupTarget
    { _backupTargetServerId = serverId,
      _backupTargetIpv4 = ipv4,
      _backupTargetRepoUser = owner,
      _backupTargetRepoName = repo,
      _backupTargetBranch = branch',
      _backupTargetConfiguration = configuration,
      _backupTargetPersistenceName = persistenceName,
      _backupTargetSection = section
    }
