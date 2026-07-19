-- | Database layer for build artifacts (garnix.yaml @artifacts:@): rows
-- linking builds to published content (the @artifacts@ table), bookkeeping
-- for the content-addressed storage objects (@artifact_objects@), and the
-- retention settings consumed by the reaper and the Configure API.
module Garnix.DB.Artifacts
  ( ArtifactRow (..),
    ArtifactDtoRow (..),
    upsertArtifact,
    getArtifactsForBuild,
    getArtifactsForRepo,
    getLatestArtifact,
    getArtifactByBuildAndName,
    setBuildArtifactsLocked,
    deleteArtifactRow,
    artifactObjectExists,
    insertArtifactObject,
    getArtifactDtosForBuild,
    getArtifactDtosForRepo,
    getArtifactDtosForCommit,
    getArtifactCommitCountsForRepo,
    reapExpiredArtifactRows,
    pruneFailedArtifactRows,
    getOrphanedArtifactObjects,
    deleteArtifactObject,
    getArtifactSettings,
    setDefaultArtifactSettings,
    setRepoArtifactSettings,
    deleteRepoArtifactSettings,
    getArtifactRepoOverrides,
    getArtifactStorageUsage,
    getLockedArtifactBuilds,
  )
where

import Database.PostgreSQL.Typed (pgSQL)
import Garnix.DB qualified as DB
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types

-- | A row of the @artifacts@ table: one (attempted) artifact publication of a
-- build. @status@ is @\"published\"@ or @\"failed\"@.
data ArtifactRow = ArtifactRow
  { _artifactRowId :: Int64,
    _artifactRowBuildId :: BuildId,
    _artifactRowRepoUser :: GhRepoOwner,
    _artifactRowRepoName :: GhRepoName,
    _artifactRowBranch :: Maybe Branch,
    _artifactRowName :: Text,
    _artifactRowStoreHash :: Text,
    _artifactRowBucket :: ArtifactBucket,
    _artifactRowStatus :: Text,
    _artifactRowLocked :: Bool,
    _artifactRowCreatedAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)

-- | An 'ArtifactRow' joined with its storage object's size/file-count (0/0
-- when no object exists, e.g. for failed publications).
data ArtifactDtoRow = ArtifactDtoRow
  { _artifactDtoRowId :: Int64,
    _artifactDtoRowBuildId :: BuildId,
    _artifactDtoRowRepoUser :: GhRepoOwner,
    _artifactDtoRowRepoName :: GhRepoName,
    _artifactDtoRowBranch :: Maybe Branch,
    _artifactDtoRowName :: Text,
    _artifactDtoRowStoreHash :: Text,
    _artifactDtoRowBucket :: ArtifactBucket,
    _artifactDtoRowStatus :: Text,
    _artifactDtoRowLocked :: Bool,
    _artifactDtoRowCreatedAt :: UTCTime,
    _artifactDtoRowTotalSize :: Int64,
    _artifactDtoRowFileCount :: Int
  }
  deriving stock (Eq, Show, Generic)

decodeBucket :: Text -> M ArtifactBucket
decodeBucket bucketText = case artifactBucketFromText bucketText of
  Just bucket -> pure bucket
  Nothing -> throw $ OtherError $ "unknown artifact bucket: " <> bucketText

toArtifactRow ::
  (Int64, BuildId, GhRepoOwner, GhRepoName, Maybe Branch, Text, Text, Text, Text, Bool, UTCTime) ->
  M ArtifactRow
toArtifactRow (rowId, buildId, repoOwner, repoName', branch', artifactName, storeHash, bucketText, status', locked, createdAt) = do
  bucket <- decodeBucket bucketText
  pure
    $ ArtifactRow
      { _artifactRowId = rowId,
        _artifactRowBuildId = buildId,
        _artifactRowRepoUser = repoOwner,
        _artifactRowRepoName = repoName',
        _artifactRowBranch = branch',
        _artifactRowName = artifactName,
        _artifactRowStoreHash = storeHash,
        _artifactRowBucket = bucket,
        _artifactRowStatus = status',
        _artifactRowLocked = locked,
        _artifactRowCreatedAt = createdAt
      }

toArtifactDtoRow ::
  (Int64, BuildId, GhRepoOwner, GhRepoName, Maybe Branch, Text, Text, Text, Text, Bool, UTCTime, Int64, Int32) ->
  M ArtifactDtoRow
toArtifactDtoRow (rowId, buildId, repoOwner, repoName', branch', artifactName, storeHash, bucketText, status', locked, createdAt, totalSize, fileCount) = do
  bucket <- decodeBucket bucketText
  pure
    $ ArtifactDtoRow
      { _artifactDtoRowId = rowId,
        _artifactDtoRowBuildId = buildId,
        _artifactDtoRowRepoUser = repoOwner,
        _artifactDtoRowRepoName = repoName',
        _artifactDtoRowBranch = branch',
        _artifactDtoRowName = artifactName,
        _artifactDtoRowStoreHash = storeHash,
        _artifactDtoRowBucket = bucket,
        _artifactDtoRowStatus = status',
        _artifactDtoRowLocked = locked,
        _artifactDtoRowCreatedAt = createdAt,
        _artifactDtoRowTotalSize = totalSize,
        _artifactDtoRowFileCount = fromIntegral fileCount
      }

-- | Record an artifact publication attempt for a build. Repo/branch are read
-- off the 'Build'; re-publishing the same (build, name) overwrites the row.
upsertArtifact :: Build -> Text -> Text -> ArtifactBucket -> Text -> M ()
upsertArtifact build artifactName storeHash bucket status' =
  void
    $ DB.pgExec
      [pgSQL|
        INSERT INTO artifacts
          (build_id, repo_user, repo_name, branch, name, store_hash, bucket, status)
          VALUES
            ( ${build ^. id},
              ${build ^. repoUser},
              ${build ^. repoName},
              ${build ^. branch},
              ${artifactName},
              ${storeHash},
              ${artifactBucketText bucket},
              ${status'}
            )
          ON CONFLICT (build_id, name)
          DO UPDATE SET
            store_hash = ${storeHash},
            bucket = ${artifactBucketText bucket},
            status = ${status'},
            created_at = now()
      |]

getArtifactsForBuild :: BuildId -> M [ArtifactRow]
getArtifactsForBuild buildId = do
  rows <-
    DB.pgQuery
      [pgSQL|
        SELECT id, build_id, repo_user, repo_name, branch, name, store_hash, bucket, status, locked, created_at
        FROM artifacts
        WHERE build_id = ${buildId}
        ORDER BY name
      |]
  mapM toArtifactRow rows

getArtifactsForRepo :: GhRepoOwner -> GhRepoName -> Maybe Branch -> M [ArtifactRow]
getArtifactsForRepo repoOwner repoName' mBranch = do
  rows <-
    DB.pgQuery
      [pgSQL|
        SELECT id, build_id, repo_user, repo_name, branch, name, store_hash, bucket, status, locked, created_at
        FROM artifacts
        WHERE repo_user = ${repoOwner}
          AND repo_name = ${repoName'}
          AND (${mBranch}::text IS NULL OR branch = ${mBranch})
        ORDER BY created_at DESC, id DESC
      |]
  mapM toArtifactRow rows

-- | The newest successfully published artifact for a repo/branch/name, backing
-- the stable latest-URLs.
getLatestArtifact :: GhRepoOwner -> GhRepoName -> Branch -> Text -> M (Maybe ArtifactRow)
getLatestArtifact repoOwner repoName' branch' artifactName = do
  rows <-
    DB.pgQuery
      [pgSQL|
        SELECT id, build_id, repo_user, repo_name, branch, name, store_hash, bucket, status, locked, created_at
        FROM artifacts
        WHERE status = 'published'
          AND repo_user = ${repoOwner}
          AND repo_name = ${repoName'}
          AND branch = ${branch'}
          AND name = ${artifactName}
        ORDER BY created_at DESC, id DESC
        LIMIT 1
      |]
  case rows of
    [] -> pure Nothing
    (row : _) -> Just <$> toArtifactRow row

getArtifactByBuildAndName :: BuildId -> Text -> M (Maybe ArtifactRow)
getArtifactByBuildAndName buildId artifactName = do
  rows <-
    DB.pgQuery
      [pgSQL|
        SELECT id, build_id, repo_user, repo_name, branch, name, store_hash, bucket, status, locked, created_at
        FROM artifacts
        WHERE build_id = ${buildId}
          AND name = ${artifactName}
        LIMIT 1
      |]
  case rows of
    [] -> pure Nothing
    (row : _) -> Just <$> toArtifactRow row

-- | Lock (or unlock) every artifact row of a build. Locked rows are never
-- reaped, whatever the retention settings say.
setBuildArtifactsLocked :: BuildId -> Bool -> M ()
setBuildArtifactsLocked buildId locked =
  void
    $ DB.pgExec
      [pgSQL|
        UPDATE artifacts
        SET locked = ${locked}
        WHERE build_id = ${buildId}
      |]

deleteArtifactRow :: Int64 -> M ()
deleteArtifactRow rowId =
  void
    $ DB.pgExec
      [pgSQL|
        DELETE FROM artifacts WHERE id = ${rowId}
      |]

-- | Whether a content-addressed object was already uploaded (dedupe check).
artifactObjectExists :: Text -> ArtifactBucket -> M Bool
artifactObjectExists storeHash bucket = do
  rows :: [Text] <-
    DB.pgQuery
      [pgSQL|
        SELECT store_hash
        FROM artifact_objects
        WHERE store_hash = ${storeHash}
          AND bucket = ${artifactBucketText bucket}
      |]
  pure $ not $ null rows

-- | Record an uploaded storage object: @insertArtifactObject storeHash bucket
-- totalSize fileCount@.
insertArtifactObject :: Text -> ArtifactBucket -> Int64 -> Int -> M ()
insertArtifactObject storeHash bucket totalSize fileCount =
  void
    $ DB.pgExec
      [pgSQL|
        INSERT INTO artifact_objects (store_hash, bucket, total_size, file_count)
          VALUES
            ( ${storeHash},
              ${artifactBucketText bucket},
              ${totalSize},
              ${fromIntegral fileCount :: Int32}
            )
          ON CONFLICT (store_hash, bucket) DO NOTHING
      |]

getArtifactDtosForBuild :: BuildId -> M [ArtifactDtoRow]
getArtifactDtosForBuild buildId = do
  rows <-
    DB.pgQuery
      -- `!` takes nullability from the Haskell types: the COALESCEd left-join
      -- columns are genuinely non-null, `a.branch` stays a Maybe.
      [pgSQL|!
        SELECT a.id, a.build_id, a.repo_user, a.repo_name, a.branch, a.name, a.store_hash, a.bucket, a.status, a.locked, a.created_at,
          COALESCE(ao.total_size, 0)::bigint, COALESCE(ao.file_count, 0)::int
        FROM artifacts a
        LEFT JOIN artifact_objects ao
          ON ao.store_hash = a.store_hash AND ao.bucket = a.bucket
        WHERE a.build_id = ${buildId}
        ORDER BY a.name
      |]
  mapM toArtifactDtoRow rows

getArtifactDtosForRepo :: GhRepoOwner -> GhRepoName -> Maybe Branch -> M [ArtifactDtoRow]
getArtifactDtosForRepo repoOwner repoName' mBranch = do
  rows <-
    DB.pgQuery
      -- see the `!` note on getArtifactDtosForBuild
      [pgSQL|!
        SELECT a.id, a.build_id, a.repo_user, a.repo_name, a.branch, a.name, a.store_hash, a.bucket, a.status, a.locked, a.created_at,
          COALESCE(ao.total_size, 0)::bigint, COALESCE(ao.file_count, 0)::int
        FROM artifacts a
        LEFT JOIN artifact_objects ao
          ON ao.store_hash = a.store_hash AND ao.bucket = a.bucket
        WHERE a.repo_user = ${repoOwner}
          AND a.repo_name = ${repoName'}
          AND (${mBranch}::text IS NULL OR a.branch = ${mBranch})
        ORDER BY a.created_at DESC, a.id DESC
      |]
  mapM toArtifactDtoRow rows

-- | All artifact DTOs whose build's commit matches, for the commit\/build
-- detail page's per-row artifact icons (see 'getArtifactDtosForBuild'\/
-- 'getArtifactDtosForRepo' for the id-\/repo-scoped equivalents this mirrors).
getArtifactDtosForCommit :: GhRepoOwner -> GhRepoName -> CommitHash -> M [ArtifactDtoRow]
getArtifactDtosForCommit repoOwner repoName' commit = do
  rows <-
    DB.pgQuery
      -- see the `!` note on getArtifactDtosForBuild
      [pgSQL|!
        SELECT a.id, a.build_id, a.repo_user, a.repo_name, a.branch, a.name, a.store_hash, a.bucket, a.status, a.locked, a.created_at,
          COALESCE(ao.total_size, 0)::bigint, COALESCE(ao.file_count, 0)::int
        FROM artifacts a
        JOIN builds b ON b.id = a.build_id
        LEFT JOIN artifact_objects ao
          ON ao.store_hash = a.store_hash AND ao.bucket = a.bucket
        WHERE a.repo_user = ${repoOwner}
          AND a.repo_name = ${repoName'}
          AND b.git_commit = ${commit}
        ORDER BY a.created_at DESC, a.id DESC
      |]
  mapM toArtifactDtoRow rows

-- | Published-artifact counts per commit, for the repo build-list page's
-- per-row badges.
getArtifactCommitCountsForRepo :: GhRepoOwner -> GhRepoName -> M [(CommitHash, Int64)]
getArtifactCommitCountsForRepo repoOwner repoName' =
  DB.pgQuery
    -- see the `!` note on getArtifactDtosForBuild: `builds.git_commit` is
    -- NOT NULL and COUNT(*) is never null.
    [pgSQL|!
      SELECT b.git_commit, COUNT(*)
      FROM artifacts a
      JOIN builds b ON b.id = a.build_id
      WHERE a.repo_user = ${repoOwner}
        AND a.repo_name = ${repoName'}
        AND a.status = 'published'
      GROUP BY b.git_commit
    |]

-- * Reaper queries

-- | Delete published, unlocked artifact rows older than the effective
-- retention (per-repo override, else the server default), except — when the
-- effective keep-latest is on — the newest row per repo\/branch\/name. Returns
-- the number of deleted rows.
reapExpiredArtifactRows :: M Int64
reapExpiredArtifactRows =
  fmap fromIntegral
    $ DB.pgExec
      [pgSQL|
        WITH s AS (
          SELECT artifact_retention_days AS d, artifact_keep_latest AS k
          FROM server_settings
          WHERE singleton
        ),
        eff AS (
          SELECT a.id,
                 COALESCE(rc.artifact_retention_days, s.d) AS retention,
                 COALESCE(rc.artifact_keep_latest, s.k) AS keep_latest,
                 row_number() OVER (
                   PARTITION BY a.repo_user, a.repo_name, a.branch, a.name
                   ORDER BY a.created_at DESC, a.id DESC
                 ) AS rn
          FROM artifacts a
          CROSS JOIN s
          LEFT JOIN repo_config rc
            ON rc.repo_user = a.repo_user AND rc.repo_name = a.repo_name
          WHERE a.status = 'published' AND NOT a.locked
        )
        DELETE FROM artifacts a
        USING eff
        WHERE a.id = eff.id
          AND a.created_at < now() - make_interval(days => eff.retention)
          AND NOT (eff.keep_latest AND eff.rn = 1)
      |]

-- | Delete failed publication rows older than 7 days. Returns the number of
-- deleted rows.
pruneFailedArtifactRows :: M Int64
pruneFailedArtifactRows =
  fmap fromIntegral
    $ DB.pgExec
      [pgSQL|
        DELETE FROM artifacts
        WHERE status = 'failed'
          AND created_at < now() - interval '7 days'
      |]

-- | Storage objects no artifact row references anymore (reap first, then GC
-- these from the bucket and drop the bookkeeping row).
getOrphanedArtifactObjects :: M [(Text, ArtifactBucket)]
getOrphanedArtifactObjects = do
  rows <-
    DB.pgQuery
      [pgSQL|
        SELECT store_hash, bucket
        FROM artifact_objects ao
        WHERE NOT EXISTS (
          SELECT 1 FROM artifacts a
          WHERE a.store_hash = ao.store_hash AND a.bucket = ao.bucket
        )
        ORDER BY store_hash, bucket
      |]
  forM rows $ \(storeHash, bucketText) -> (storeHash,) <$> decodeBucket bucketText

deleteArtifactObject :: Text -> ArtifactBucket -> M ()
deleteArtifactObject storeHash bucket =
  void
    $ DB.pgExec
      [pgSQL|
        DELETE FROM artifact_objects
        WHERE store_hash = ${storeHash}
          AND bucket = ${artifactBucketText bucket}
      |]

-- * Retention settings

-- | The global default (retention days, keep-latest). Guarantees the
-- server_settings singleton row exists, so the reaper's CTE always finds it.
getArtifactSettings :: M (Int32, Bool)
getArtifactSettings = do
  void
    $ DB.pgExec
      [pgSQL|
        INSERT INTO server_settings (singleton) VALUES (true)
          ON CONFLICT (singleton) DO NOTHING
      |]
  rows <-
    DB.pgQuery
      [pgSQL|
        SELECT artifact_retention_days, artifact_keep_latest
        FROM server_settings
        WHERE singleton
      |]
  case rows of
    (settings : _) -> pure settings
    [] -> pure (30, False)

setDefaultArtifactSettings :: Int32 -> Bool -> M ()
setDefaultArtifactSettings retentionDays keepLatest =
  void
    $ DB.pgExec
      [pgSQL|
        INSERT INTO server_settings (singleton, artifact_retention_days, artifact_keep_latest)
          VALUES (true, ${retentionDays}, ${keepLatest})
          ON CONFLICT (singleton)
          DO UPDATE SET
            artifact_retention_days = ${retentionDays},
            artifact_keep_latest = ${keepLatest}
      |]

-- | Set a repo's retention override. 'Nothing' fields fall back to the server
-- default.
setRepoArtifactSettings :: GhRepoOwner -> GhRepoName -> Maybe Int32 -> Maybe Bool -> M ()
setRepoArtifactSettings repoOwner repoName' mRetentionDays mKeepLatest =
  void
    $ DB.pgExec
      [pgSQL|
        INSERT INTO repo_config (repo_user, repo_name, artifact_retention_days, artifact_keep_latest)
          VALUES (${repoOwner}, ${repoName'}, ${mRetentionDays}, ${mKeepLatest})
          ON CONFLICT (repo_user, repo_name)
          DO UPDATE SET
            artifact_retention_days = ${mRetentionDays},
            artifact_keep_latest = ${mKeepLatest}
      |]

deleteRepoArtifactSettings :: GhRepoOwner -> GhRepoName -> M ()
deleteRepoArtifactSettings repoOwner repoName' =
  void
    $ DB.pgExec
      [pgSQL|
        UPDATE repo_config
        SET artifact_retention_days = NULL, artifact_keep_latest = NULL
        WHERE repo_user = ${repoOwner}
          AND repo_name = ${repoName'}
      |]

-- | Every repo with an artifact retention override.
getArtifactRepoOverrides :: M [(GhRepoOwner, GhRepoName, Maybe Int32, Maybe Bool)]
getArtifactRepoOverrides =
  DB.pgQuery
    [pgSQL|
      SELECT repo_user, repo_name, artifact_retention_days, artifact_keep_latest
      FROM repo_config
      WHERE artifact_retention_days IS NOT NULL
         OR artifact_keep_latest IS NOT NULL
      ORDER BY repo_user, repo_name
    |]

-- | Per-repo artifact storage usage in bytes. Objects are content-addressed
-- and shared between rows, so each distinct (store_hash, bucket) counts once
-- per repo.
getArtifactStorageUsage :: M [(GhRepoOwner, GhRepoName, Int64)]
getArtifactStorageUsage =
  DB.pgQuery
    -- see the `!` note on getArtifactDtosForBuild: the COALESCEd SUM is
    -- genuinely non-null, the grouped columns come from NOT NULL columns.
    [pgSQL|!
      SELECT repo_user, repo_name, COALESCE(SUM(total_size), 0)::bigint
      FROM (
        SELECT DISTINCT a.repo_user, a.repo_name, a.store_hash, a.bucket, ao.total_size
        FROM artifacts a
        JOIN artifact_objects ao
          ON ao.store_hash = a.store_hash AND ao.bucket = a.bucket
      ) AS per_object
      GROUP BY repo_user, repo_name
      ORDER BY repo_user, repo_name
    |]

-- | Every locked artifact row (the Configure page's locked-builds table).
getLockedArtifactBuilds :: M [ArtifactRow]
getLockedArtifactBuilds = do
  rows <-
    DB.pgQuery
      [pgSQL|
        SELECT id, build_id, repo_user, repo_name, branch, name, store_hash, bucket, status, locked, created_at
        FROM artifacts
        WHERE locked
        ORDER BY created_at DESC, id DESC
      |]
  mapM toArtifactRow rows
