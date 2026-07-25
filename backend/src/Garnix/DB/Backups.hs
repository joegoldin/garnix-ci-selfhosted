-- | Database layer for scheduled server backups (garnix.yaml @backups:@):
-- snapshot rows (which deliberately OUTLIVE their server — restoring after
-- accidental server deletion is the point), content-addressed object
-- bookkeeping, restore audit rows, the retention settings consumed by the
-- reaper and the Configure API, and the per-server backups config captured
-- at deploy time.
module Garnix.DB.Backups
  ( BackupRow (..),
    insertRunningBackup,
    finalizeBackupSuccess,
    finalizeBackupFailure,
    hasRunningBackup,
    getBackupRow,
    getBackupsForRepo,
    getBackupsForServerConfig,
    getLatestSuccessfulBackup,
    setBackupLocked,
    deleteBackupRow,
    upsertBackupObject,
    backupObjectExists,
    getOrphanedBackupObjects,
    deleteBackupObject,
    reapExpiredBackupRows,
    pruneFailedBackupRows,
    failStaleRunningBackups,
    getLiveBackupTargets,
    getServerRepoAndConfig,
    getBackupTargetForServer,
    getLiveServerForConfig,
    getBackupSettings,
    setDefaultBackupSettings,
    setRepoBackupSettings,
    deleteRepoBackupSettings,
    getBackupRepoOverrides,
    getBackupStorageUsage,
    getLockedBackups,
    insertRunningRestore,
    finalizeRestoreSuccess,
    finalizeRestoreFailure,
    getRestoresForServerConfig,
    setServerBackups,
    getServerBackups,
  )
where

import Data.Aeson qualified as Aeson
import Database.PostgreSQL.Typed (pgSQL)
import Garnix.DB qualified as DB
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import Garnix.YamlConfig (BackupSection)

-- | A row of the @backups@ table: one (attempted) snapshot of a live
-- server's configured paths. @status@ is @\"running\"@, @\"success\"@, or
-- @\"failed\"@. @server_id@ is nulled out (but the row kept) when the server
-- is deleted — repo/branch/configuration/persistence_name are denormalized
-- onto the row for exactly that reason.
data BackupRow = BackupRow
  { _backupRowId :: Int64,
    _backupRowServerId :: Maybe ServerId,
    _backupRowRepoUser :: GhRepoOwner,
    _backupRowRepoName :: GhRepoName,
    _backupRowBranch :: Maybe Branch,
    _backupRowConfiguration :: Text,
    _backupRowPersistenceName :: Maybe Text,
    _backupRowObjectHash :: Maybe Text,
    _backupRowStatus :: Text,
    _backupRowError :: Maybe Text,
    _backupRowKind :: Text,
    _backupRowLocked :: Bool,
    _backupRowSize :: Maybe Int64,
    _backupRowStartedAt :: UTCTime,
    _backupRowFinishedAt :: Maybe UTCTime
  }
  deriving stock (Eq, Show, Generic)

-- | The one shared tuple->BackupRow mapping used by every query that
-- returns full rows (keeps the column list and field order in one place).
toBackupRow ::
  (Int64, Maybe ServerId, GhRepoOwner, GhRepoName, Maybe Branch, Text, Maybe Text, Maybe Text, Text, Maybe Text, Text, Bool, Maybe Int64, UTCTime, Maybe UTCTime) ->
  BackupRow
toBackupRow (rowId, serverId, repoOwner, repoName', branch', configuration, persistenceName, objectHash, status', error', kind, locked, size, startedAt, finishedAt) =
  BackupRow
    { _backupRowId = rowId,
      _backupRowServerId = serverId,
      _backupRowRepoUser = repoOwner,
      _backupRowRepoName = repoName',
      _backupRowBranch = branch',
      _backupRowConfiguration = configuration,
      _backupRowPersistenceName = persistenceName,
      _backupRowObjectHash = objectHash,
      _backupRowStatus = status',
      _backupRowError = error',
      _backupRowKind = kind,
      _backupRowLocked = locked,
      _backupRowSize = size,
      _backupRowStartedAt = startedAt,
      _backupRowFinishedAt = finishedAt
    }

-- | Start a new backup attempt: @insertRunningBackup serverId owner repo
-- branch configuration persistenceName kind@. Returns the new row's id.
insertRunningBackup :: ServerId -> GhRepoOwner -> GhRepoName -> Maybe Branch -> Text -> Maybe Text -> Text -> M Int64
insertRunningBackup serverId repoOwner repoName' branch' configuration persistenceName kind = do
  rows <-
    DB.pgQuery
      [pgSQL|
        INSERT INTO backups
          (server_id, repo_user, repo_name, branch, configuration, persistence_name, status, kind)
          VALUES
            ( ${serverId},
              ${repoOwner},
              ${repoName'},
              ${branch'},
              ${configuration},
              ${persistenceName},
              'running',
              ${kind}
            )
          RETURNING id
      |]
  case rows of
    (rowId : _) -> pure rowId
    [] -> throw $ OtherError "insertRunningBackup: insert returned no id"

finalizeBackupSuccess :: Int64 -> Text -> Int64 -> M ()
finalizeBackupSuccess backupId objectHash size =
  void
    $ DB.pgExec
      [pgSQL|
        UPDATE backups
        SET status = 'success',
            object_hash = ${objectHash},
            size = ${size},
            finished_at = now()
        WHERE id = ${backupId}
      |]

finalizeBackupFailure :: Int64 -> Text -> M ()
finalizeBackupFailure backupId error' =
  void
    $ DB.pgExec
      [pgSQL|
        UPDATE backups
        SET status = 'failed',
            error = ${error'},
            finished_at = now()
        WHERE id = ${backupId}
      |]

hasRunningBackup :: ServerId -> M Bool
hasRunningBackup serverId = do
  rows :: [Int64] <-
    DB.pgQuery
      [pgSQL|
        SELECT id FROM backups
        WHERE server_id = ${serverId} AND status = 'running'
        LIMIT 1
      |]
  pure $ not $ null rows

getBackupRow :: Int64 -> M (Maybe BackupRow)
getBackupRow backupId = do
  rows <-
    DB.pgQuery
      [pgSQL|
        SELECT id, server_id, repo_user, repo_name, branch, configuration, persistence_name, object_hash, status, error, kind, locked, size, started_at, finished_at
        FROM backups
        WHERE id = ${backupId}
      |]
  pure $ case rows of
    [] -> Nothing
    (row : _) -> Just (toBackupRow row)

getBackupsForRepo :: GhRepoOwner -> GhRepoName -> M [BackupRow]
getBackupsForRepo repoOwner repoName' = do
  rows <-
    DB.pgQuery
      [pgSQL|
        SELECT id, server_id, repo_user, repo_name, branch, configuration, persistence_name, object_hash, status, error, kind, locked, size, started_at, finished_at
        FROM backups
        WHERE repo_user = ${repoOwner} AND repo_name = ${repoName'}
        ORDER BY started_at DESC, id DESC
      |]
  pure $ map toBackupRow rows

-- | All backup rows for a repo's specific deployed configuration, including
-- prior server incarnations (rows aren't filtered by @server_id@).
getBackupsForServerConfig :: GhRepoOwner -> GhRepoName -> Text -> M [BackupRow]
getBackupsForServerConfig repoOwner repoName' configuration = do
  rows <-
    DB.pgQuery
      [pgSQL|
        SELECT id, server_id, repo_user, repo_name, branch, configuration, persistence_name, object_hash, status, error, kind, locked, size, started_at, finished_at
        FROM backups
        WHERE repo_user = ${repoOwner} AND repo_name = ${repoName'} AND configuration = ${configuration}
        ORDER BY started_at DESC, id DESC
      |]
  pure $ map toBackupRow rows

getLatestSuccessfulBackup :: GhRepoOwner -> GhRepoName -> Text -> M (Maybe BackupRow)
getLatestSuccessfulBackup repoOwner repoName' configuration = do
  rows <-
    DB.pgQuery
      [pgSQL|
        SELECT id, server_id, repo_user, repo_name, branch, configuration, persistence_name, object_hash, status, error, kind, locked, size, started_at, finished_at
        FROM backups
        WHERE repo_user = ${repoOwner} AND repo_name = ${repoName'} AND configuration = ${configuration}
          AND status = 'success'
        ORDER BY started_at DESC, id DESC
        LIMIT 1
      |]
  pure $ case rows of
    [] -> Nothing
    (row : _) -> Just (toBackupRow row)

setBackupLocked :: Int64 -> Bool -> M ()
setBackupLocked backupId locked =
  void
    $ DB.pgExec
      [pgSQL|
        UPDATE backups SET locked = ${locked} WHERE id = ${backupId}
      |]

deleteBackupRow :: Int64 -> M ()
deleteBackupRow backupId =
  void
    $ DB.pgExec
      [pgSQL|
        DELETE FROM backups WHERE id = ${backupId}
      |]

-- | Record an uploaded content-addressed backup object. @upsertBackupObject
-- hash totalSize@; a repeat of the same hash is a no-op.
upsertBackupObject :: Text -> Int64 -> M ()
upsertBackupObject objectHash totalSize =
  void
    $ DB.pgExec
      [pgSQL|
        INSERT INTO backup_objects (object_hash, total_size)
          VALUES (${objectHash}, ${totalSize})
          ON CONFLICT (object_hash) DO NOTHING
      |]

backupObjectExists :: Text -> M Bool
backupObjectExists objectHash = do
  rows :: [Text] <-
    DB.pgQuery
      [pgSQL|
        SELECT object_hash FROM backup_objects WHERE object_hash = ${objectHash}
      |]
  pure $ not $ null rows

-- | Storage objects no backup row references anymore (reap first, then GC
-- these from the bucket and drop the bookkeeping row).
getOrphanedBackupObjects :: M [Text]
getOrphanedBackupObjects =
  DB.pgQuery
    [pgSQL|
      SELECT object_hash
      FROM backup_objects bo
      WHERE NOT EXISTS (
        SELECT 1 FROM backups b WHERE b.object_hash = bo.object_hash
      )
      ORDER BY object_hash
    |]

deleteBackupObject :: Text -> M ()
deleteBackupObject objectHash =
  void
    $ DB.pgExec
      [pgSQL|
        DELETE FROM backup_objects WHERE object_hash = ${objectHash}
      |]

-- * Reaper queries

-- | Delete successful, unlocked backup rows older than the effective
-- retention (per-repo override, else the server default), except — when the
-- effective keep-latest is on (the DEFAULT for backups, unlike artifacts) —
-- the newest successful row per repo/configuration.
reapExpiredBackupRows :: M Int64
reapExpiredBackupRows =
  fmap fromIntegral
    $ DB.pgExec
      [pgSQL|
        WITH s AS (
          SELECT backup_retention_days AS d, backup_keep_latest AS k
          FROM server_settings
          WHERE singleton
        ),
        eff AS (
          SELECT b.id,
                 COALESCE(rc.backup_retention_days, s.d) AS retention,
                 COALESCE(rc.backup_keep_latest, s.k) AS keep_latest,
                 row_number() OVER (
                   PARTITION BY b.repo_user, b.repo_name, b.configuration
                   ORDER BY b.started_at DESC, b.id DESC
                 ) AS rn
          FROM backups b
          CROSS JOIN s
          LEFT JOIN repo_config rc
            ON rc.repo_user = b.repo_user AND rc.repo_name = b.repo_name
          WHERE b.status = 'success' AND NOT b.locked
        )
        DELETE FROM backups b
        USING eff
        WHERE b.id = eff.id
          AND b.started_at < now() - make_interval(days => eff.retention)
          AND NOT (eff.keep_latest AND eff.rn = 1)
      |]

-- | Delete failed backup rows older than 7 days. Returns the number of
-- deleted rows.
pruneFailedBackupRows :: M Int64
pruneFailedBackupRows =
  fmap fromIntegral
    $ DB.pgExec
      [pgSQL|
        DELETE FROM backups
        WHERE status = 'failed'
          AND started_at < now() - interval '7 days'
      |]

-- | Fail @running@ rows that have been running for more than 2 hours —
-- almost certainly orphaned by a server/process restart or crash mid-backup.
failStaleRunningBackups :: M Int64
failStaleRunningBackups =
  fmap fromIntegral
    $ DB.pgExec
      [pgSQL|
        UPDATE backups
        SET status = 'failed',
            error = 'orphaned by restart or crash',
            finished_at = now()
        WHERE status = 'running'
          AND started_at < now() - interval '2 hours'
      |]

-- | Live servers (ready, not ended) whose deploy captured a backups config,
-- with the started_at of their configuration's most recent successful backup.
getLiveBackupTargets :: M [(ServerId, Text, GhRepoOwner, GhRepoName, Maybe Branch, Text, Maybe Text, Text, Maybe UTCTime)]
getLiveBackupTargets =
  DB.pgQuery
    -- `!` takes nullability from the Haskell types: `s.backups::text` is
    -- genuinely non-null here (WHERE s.backups IS NOT NULL), but a cast
    -- expression's nullability isn't inferred from the query's own WHERE
    -- clause (see the `!` note on Artifacts.getArtifactDtosForBuild).
    [pgSQL|!
      SELECT s.id, s.ipv4, b.repo_user, b.repo_name, b.branch, b.package,
             b.persistence_name, s.backups::text,
             ( SELECT max(bk.started_at) FROM backups bk
               WHERE bk.repo_user = b.repo_user AND bk.repo_name = b.repo_name
                 AND bk.configuration = b.package AND bk.status = 'success' )
      FROM servers s
      JOIN builds b ON b.id = s.configuration_build_id
      WHERE s.ready_at IS NOT NULL
        AND s.ended_at IS NULL
        AND s.backups IS NOT NULL
      ORDER BY s.id
    |]

-- | The repo and configuration a server was deployed from, for authorizing
-- server-scoped API calls. Independent of whether backups are configured
-- (an unconfigured server still has a repo whose access gates its listing).
getServerRepoAndConfig :: ServerId -> M (Maybe (GhRepoOwner, GhRepoName, Text))
getServerRepoAndConfig serverId = do
  rows <-
    DB.pgQuery
      [pgSQL|
        SELECT b.repo_user, b.repo_name, b.package
        FROM servers s
        JOIN builds b ON b.id = s.configuration_build_id
        WHERE s.id = ${serverId}
      |]
  pure $ case rows of
    [] -> Nothing
    (row : _) -> Just row

-- | One live server's backup target row — the same shape as
-- 'getLiveBackupTargets' minus the last-success column — for a manual
-- \"backup now\". 'Nothing' when the server isn't live or its deploy
-- captured no @backups:@ config.
getBackupTargetForServer ::
  ServerId ->
  M (Maybe (ServerId, Text, GhRepoOwner, GhRepoName, Maybe Branch, Text, Maybe Text, Text))
getBackupTargetForServer serverId = do
  rows <-
    DB.pgQuery
      -- `!` for the same reason as 'getLiveBackupTargets': the
      -- `s.backups::text` cast's nullability isn't inferred from the WHERE.
      [pgSQL|!
        SELECT s.id, s.ipv4, b.repo_user, b.repo_name, b.branch, b.package,
               b.persistence_name, s.backups::text
        FROM servers s
        JOIN builds b ON b.id = s.configuration_build_id
        WHERE s.id = ${serverId}
          AND s.ready_at IS NOT NULL
          AND s.ended_at IS NULL
          AND s.backups IS NOT NULL
      |]
  pure $ case rows of
    [] -> Nothing
    (row : _) -> Just row

-- | The server currently live for a repo's configuration — the restore
-- target. Restores always land on the CURRENT incarnation, never on the
-- (possibly long-deleted) server the snapshot was taken from.
getLiveServerForConfig :: GhRepoOwner -> GhRepoName -> Text -> M (Maybe ServerInfo)
getLiveServerForConfig repoOwner repoName' configuration = do
  servers <-
    DB.pgQueryPrism
      _ServerInfo
      [pgSQL|
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
        INNER JOIN builds ON servers.configuration_build_id = builds.id
        WHERE builds.repo_user = ${repoOwner}
          AND builds.repo_name = ${repoName'}
          AND builds.package = ${configuration}
          AND servers.ready_at IS NOT NULL
          AND servers.ended_at IS NULL
        ORDER BY servers.created_at DESC, servers.id DESC
        LIMIT 1
      |]
  pure $ case servers of
    [] -> Nothing
    (server : _) -> Just server

-- * Retention settings

-- | The global default (retention days, keep-latest). Guarantees the
-- server_settings singleton row exists, so the reaper's CTE always finds it.
getBackupSettings :: M (Int32, Bool)
getBackupSettings = do
  void
    $ DB.pgExec
      [pgSQL|
        INSERT INTO server_settings (singleton) VALUES (true)
          ON CONFLICT (singleton) DO NOTHING
      |]
  rows <-
    DB.pgQuery
      [pgSQL|
        SELECT backup_retention_days, backup_keep_latest
        FROM server_settings
        WHERE singleton
      |]
  case rows of
    (settings : _) -> pure settings
    [] -> pure (30, True)

setDefaultBackupSettings :: Int32 -> Bool -> M ()
setDefaultBackupSettings retentionDays keepLatest =
  void
    $ DB.pgExec
      [pgSQL|
        INSERT INTO server_settings (singleton, backup_retention_days, backup_keep_latest)
          VALUES (true, ${retentionDays}, ${keepLatest})
          ON CONFLICT (singleton)
          DO UPDATE SET
            backup_retention_days = ${retentionDays},
            backup_keep_latest = ${keepLatest}
      |]

-- | Set a repo's retention override. 'Nothing' fields fall back to the
-- server default.
setRepoBackupSettings :: GhRepoOwner -> GhRepoName -> Maybe Int32 -> Maybe Bool -> M ()
setRepoBackupSettings repoOwner repoName' mRetentionDays mKeepLatest =
  void
    $ DB.pgExec
      [pgSQL|
        INSERT INTO repo_config (repo_user, repo_name, backup_retention_days, backup_keep_latest)
          VALUES (${repoOwner}, ${repoName'}, ${mRetentionDays}, ${mKeepLatest})
          ON CONFLICT (repo_user, repo_name)
          DO UPDATE SET
            backup_retention_days = ${mRetentionDays},
            backup_keep_latest = ${mKeepLatest}
      |]

deleteRepoBackupSettings :: GhRepoOwner -> GhRepoName -> M ()
deleteRepoBackupSettings repoOwner repoName' =
  void
    $ DB.pgExec
      [pgSQL|
        UPDATE repo_config
        SET backup_retention_days = NULL, backup_keep_latest = NULL
        WHERE repo_user = ${repoOwner}
          AND repo_name = ${repoName'}
      |]

-- | Every repo with a backup retention override.
getBackupRepoOverrides :: M [(GhRepoOwner, GhRepoName, Maybe Int32, Maybe Bool)]
getBackupRepoOverrides =
  DB.pgQuery
    [pgSQL|
      SELECT repo_user, repo_name, backup_retention_days, backup_keep_latest
      FROM repo_config
      WHERE backup_retention_days IS NOT NULL
         OR backup_keep_latest IS NOT NULL
      ORDER BY repo_user, repo_name
    |]

-- | Per-repo backup storage usage in bytes. Objects are content-addressed
-- and shared between rows, so each distinct object_hash counts once per
-- repo.
getBackupStorageUsage :: M [(GhRepoOwner, GhRepoName, Int64)]
getBackupStorageUsage =
  DB.pgQuery
    -- see the `!` note on Artifacts.getArtifactDtosForBuild: the COALESCEd
    -- SUM is genuinely non-null, the grouped columns come from NOT NULL
    -- columns.
    [pgSQL|!
      SELECT repo_user, repo_name, COALESCE(SUM(total_size), 0)::bigint
      FROM (
        SELECT DISTINCT b.repo_user, b.repo_name, b.object_hash, bo.total_size
        FROM backups b
        JOIN backup_objects bo ON bo.object_hash = b.object_hash
      ) AS per_object
      GROUP BY repo_user, repo_name
      ORDER BY repo_user, repo_name
    |]

-- | Every locked backup row (the Configure/Servers page's locked-backups
-- table).
getLockedBackups :: M [BackupRow]
getLockedBackups = do
  rows <-
    DB.pgQuery
      [pgSQL|
        SELECT id, server_id, repo_user, repo_name, branch, configuration, persistence_name, object_hash, status, error, kind, locked, size, started_at, finished_at
        FROM backups
        WHERE locked
        ORDER BY started_at DESC, id DESC
      |]
  pure $ map toBackupRow rows

-- * Restores

-- | Start a restore attempt: @insertRunningRestore backupId serverId
-- initiatedBy@. Returns the new row's id.
insertRunningRestore :: Int64 -> ServerId -> Text -> M Int64
insertRunningRestore backupId serverId initiatedBy = do
  rows <-
    DB.pgQuery
      [pgSQL|
        INSERT INTO backup_restores (backup_id, server_id, status, initiated_by)
          VALUES (${backupId}, ${serverId}, 'running', ${initiatedBy})
          RETURNING id
      |]
  case rows of
    (rowId : _) -> pure rowId
    [] -> throw $ OtherError "insertRunningRestore: insert returned no id"

finalizeRestoreSuccess :: Int64 -> M ()
finalizeRestoreSuccess restoreId =
  void
    $ DB.pgExec
      [pgSQL|
        UPDATE backup_restores
        SET status = 'success', finished_at = now()
        WHERE id = ${restoreId}
      |]

finalizeRestoreFailure :: Int64 -> Text -> M ()
finalizeRestoreFailure restoreId error' =
  void
    $ DB.pgExec
      [pgSQL|
        UPDATE backup_restores
        SET status = 'failed', error = ${error'}, finished_at = now()
        WHERE id = ${restoreId}
      |]

getRestoresForServerConfig :: GhRepoOwner -> GhRepoName -> Text -> M [(Int64, Int64, Text, Maybe Text, Text, UTCTime, Maybe UTCTime)]
getRestoresForServerConfig repoOwner repoName' configuration =
  DB.pgQuery
    [pgSQL|
      SELECT r.id, r.backup_id, r.status, r.error, r.initiated_by, r.started_at, r.finished_at
      FROM backup_restores r
      JOIN backups b ON b.id = r.backup_id
      WHERE b.repo_user = ${repoOwner}
        AND b.repo_name = ${repoName'}
        AND b.configuration = ${configuration}
      ORDER BY r.started_at DESC, r.id DESC
    |]

-- * Per-server backups config (captured at deploy time)

setServerBackups :: ServerId -> Maybe BackupSection -> M ()
setServerBackups serverId section = do
  let encoded = cs . Aeson.encode <$> section :: Maybe Text
  void
    $ DB.pgExec
      [pgSQL|
        UPDATE servers
        SET backups = ${encoded}::text::jsonb
        WHERE id = ${serverId}
      |]

getServerBackups :: ServerId -> M (Maybe BackupSection)
getServerBackups serverId = do
  rows <-
    DB.pgQuery
      [pgSQL|
        SELECT backups::text FROM servers WHERE id = ${serverId}
      |]
  pure $ case rows of
    [Just t] -> Aeson.decode (cs (t :: Text))
    _ -> Nothing
