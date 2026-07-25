-- | Retention reaper for server backups: hourly; deletes expired successful
-- rows (per-repo overrides, locks, keep-latest — which DEFAULTS ON for
-- backups), prunes stale failed rows, sweeps running rows orphaned by a
-- backend restart, then GCs unreferenced storage objects (bucket object
-- first, bookkeeping row second, so a crash in between retries next pass).
module Garnix.Backups.Reaper
  ( initializeBackupReaper,
    reapOnce,
  )
where

import Garnix.Backups (backupObjectKey)
import Garnix.DB.Backups qualified as DB
import Garnix.Duration
import Garnix.Monad
import Garnix.Monad.NoThrow qualified as NoThrow
import Garnix.Prelude

-- | Fork the hourly reaper thread. 'NoThrow.forkForever' catches and logs
-- errors, so one failing pass never kills the thread.
initializeBackupReaper :: M ThreadId
initializeBackupReaper = withTextSpan ("tag", "backup reaper thread") $ do
  NoThrow.forkForever (fromHours @Int 1) reapOnce

reapOnce :: M ()
reapOnce = do
  stale <- DB.failStaleRunningBackups
  when (stale > 0)
    $ log Informational
    $ "backup reaper: failed "
    <> show stale
    <> " stale running backups"
  reaped <- DB.reapExpiredBackupRows
  when (reaped > 0)
    $ log Informational
    $ "backup reaper: deleted "
    <> show reaped
    <> " expired backup rows"
  pruned <- DB.pruneFailedBackupRows
  when (pruned > 0)
    $ log Informational
    $ "backup reaper: pruned "
    <> show pruned
    <> " failed backup rows"
  view #backupStore >>= \case
    Nothing -> pure ()
    Just store -> do
      orphans <- DB.getOrphanedBackupObjects
      forM_ orphans $ \hash -> do
        _backupStoreDeleteObject store (backupObjectKey hash)
        DB.deleteBackupObject hash
