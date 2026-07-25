-- | The backup scheduler: every 5 minutes, find live servers whose backups
-- are due and run them sequentially (one guest at a time — backups are IO- and
-- network-heavy; a household-scale instance never needs parallel capture).
module Garnix.Backups.Scheduler
  ( initializeBackupScheduler,
    schedulerPass,
  )
where

import Garnix.Backups
import Garnix.DB.Backups qualified as DB
import Garnix.Duration
import Garnix.Monad
import Garnix.Monad.NoThrow qualified as NoThrow
import Garnix.Prelude

-- | Fork the 5-minute scheduler thread. 'NoThrow.forkForever' catches and
-- logs errors, so one failing pass never kills the thread.
initializeBackupScheduler :: M ThreadId
initializeBackupScheduler = withTextSpan ("tag", "backup scheduler thread") $ do
  NoThrow.forkForever (fromMinutes @Int 5) schedulerPass

schedulerPass :: M ()
schedulerPass =
  view #backupStore >>= \case
    Nothing -> pure ()
    Just store -> do
      now <- liftIO getCurrentTime
      targets <- decodeBackupTargets <$> DB.getLiveBackupTargets
      let due = [t | (t, lastSuccess) <- targets, isDue now (_backupTargetSection t) lastSuccess]
      forM_ due $ \target -> runServerBackup store target "scheduled"
