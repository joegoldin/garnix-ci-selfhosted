-- | Retention reaper for build artifacts: an hourly background thread that
-- deletes expired\/failed artifact rows (honoring per-repo retention
-- overrides, locks and keep-latest — see
-- 'Garnix.DB.Artifacts.reapExpiredArtifactRows') and then garbage-collects
-- storage objects no row references anymore.
module Garnix.Artifacts.Reaper
  ( initializeArtifactReaper,
    reapOnce,
  )
where

import Garnix.DB.Artifacts qualified as DB
import Garnix.Duration
import Garnix.Monad
import Garnix.Monad.NoThrow qualified as NoThrow
import Garnix.Prelude

-- | Fork the hourly reaper thread. 'NoThrow.forkForever' catches and logs
-- errors, so one failing pass never kills the thread.
initializeArtifactReaper :: M ThreadId
initializeArtifactReaper = withTextSpan ("tag", "artifact reaper thread") $ do
  NoThrow.forkForever (fromHours @Int 1) reapOnce

-- | One reaper pass: delete expired rows and stale failed rows, then GC
-- orphaned storage objects — bucket prefix first, bookkeeping row second, so a
-- crash in between re-attempts the object on the next pass. Object GC is
-- skipped when no artifact store is configured.
reapOnce :: M ()
reapOnce = do
  reaped <- DB.reapExpiredArtifactRows
  when (reaped > 0)
    $ log Informational
    $ "artifact reaper: deleted "
    <> show reaped
    <> " expired artifact rows"
  pruned <- DB.pruneFailedArtifactRows
  when (pruned > 0)
    $ log Informational
    $ "artifact reaper: pruned "
    <> show pruned
    <> " failed artifact rows"
  view #artifactStore >>= \case
    Nothing -> pure ()
    Just store -> do
      orphans <- DB.getOrphanedArtifactObjects
      forM_ orphans $ \(storeHash, bucket) -> do
        _artifactStoreDeletePrefix store bucket ("artifacts/" <> storeHash <> "/")
        DB.deleteArtifactObject storeHash bucket
