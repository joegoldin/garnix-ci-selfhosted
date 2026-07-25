-- | Server-backup capture pipeline: SSH-pull a tar of the configured paths
-- from a live guest, compress, content-address, upload. The backend is the
-- only credential holder — guests never see bucket keys (design:
-- docs/plans/2026-07-20-server-backups-design.md).
module Garnix.Backups
  ( BackupTarget (..),
    runServerBackup,
    backupObjectKey,
    decodeBackupTargets,
    isDue,
  )
where

import Control.Exception (evaluate)
import Cradle
import Data.Aeson qualified as Aeson
import Data.Maybe (mapMaybe)
import Data.Text qualified as T
import Garnix.DB.Backups qualified as DB
import Garnix.Hosting.ServerPool qualified as ServerPool
import Garnix.Monad
import Garnix.Monad.SubProcess (runSubProcess, runSubProcess_)
import Garnix.Prelude
import Garnix.S3Cache (getFileHash)
import Garnix.Types
import Garnix.YamlConfig (BackupSchedule (..), BackupSection (..))
import System.Directory (getFileSize)
import System.IO (IOMode (WriteMode), hGetContents, withFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Proc

data BackupTarget = BackupTarget
  { _backupTargetServerId :: ServerId,
    _backupTargetIpv4 :: Text,
    _backupTargetRepoUser :: GhRepoOwner,
    _backupTargetRepoName :: GhRepoName,
    _backupTargetBranch :: Maybe Branch,
    _backupTargetConfiguration :: Text,
    _backupTargetPersistenceName :: Maybe Text,
    _backupTargetSection :: BackupSection
  }

backupObjectKey :: Text -> Text
backupObjectKey hash = "backups/" <> hash <> ".tar.zst"

-- | A target is due when it has never succeeded, or the last success is at
-- least the schedule interval old.
isDue :: UTCTime -> BackupSection -> Maybe UTCTime -> Bool
isDue _ _ Nothing = True
isDue now section (Just lastSuccess) =
  diffUTCTime now lastSuccess
    >= fromIntegral (_backupScheduleHours (_backupSectionSchedule section) * 3600)

-- | Decode 'Garnix.DB.Backups.getLiveBackupTargets' rows; rows whose
-- @servers.backups@ jsonb no longer decodes (config format drift) are
-- dropped rather than crashing the scheduler pass.
decodeBackupTargets ::
  [(ServerId, Text, GhRepoOwner, GhRepoName, Maybe Branch, Text, Maybe Text, Text, Maybe UTCTime)] ->
  [(BackupTarget, Maybe UTCTime)]
decodeBackupTargets = mapMaybe decodeOne
  where
    decodeOne (serverId, ipv4, owner, repo, branch', config, persistence, jsonText, lastSuccess) =
      case Aeson.decode (cs jsonText) of
        Nothing -> Nothing
        Just section ->
          Just (BackupTarget serverId ipv4 owner repo branch' config persistence section, lastSuccess)

-- | One full backup run. Inserts a running row first; ANY failure finalizes
-- it as failed (with the error) and never propagates — the scheduler loop
-- must survive every kind of broken guest.
runServerBackup :: BackupStore -> BackupTarget -> Text -> M ()
runServerBackup store target kind = do
  alreadyRunning <- DB.hasRunningBackup (_backupTargetServerId target)
  if alreadyRunning
    then log Informational $ "backup: skipping " <> show (_backupTargetServerId target) <> ", one is already running"
    else do
      backupId <-
        DB.insertRunningBackup
          (_backupTargetServerId target)
          (_backupTargetRepoUser target)
          (_backupTargetRepoName target)
          (_backupTargetBranch target)
          (_backupTargetConfiguration target)
          (_backupTargetPersistenceName target)
          kind
      capture backupId `catchEither` \e -> do
        let msg = either show show e
        log Informational $ "backup " <> show backupId <> " failed: " <> msg
        DB.finalizeBackupFailure backupId msg
  where
    section = _backupTargetSection target

    capture backupId = withSystemTempDirectory "garnix-backup" $ \tmpDir -> do
      let spool = tmpDir <> "/backup.tar"
      (ip, sshArgs) <- ServerPool.sshArgsForAddress (_backupTargetIpv4 target)
      -- 1. pre-hook (10 min cap via guest coreutils timeout)
      forM_ (_backupSectionPreBackupCommand section) $ \hook ->
        runHook sshArgs ip "preBackupCommand" hook
      -- 2. tar stream -> spool (binary; cradle captures Text, so use
      --    System.Process with a file handle; 30 min cap via local timeout)
      let remoteTar =
            "sudo -n tar --sort=name --numeric-owner -cf - "
              <> T.intercalate " " (map shellQuote (_backupSectionPaths section))
      tarResult <- liftIO $ withFile spool WriteMode $ \h -> do
        (_, _, mErr, ph) <-
          Proc.createProcess
            ( Proc.proc
                "timeout"
                (["1800", "ssh"] <> map cs sshArgs <> [cs ("garnix@" <> ip), cs remoteTar])
            )
              { Proc.std_out = Proc.UseHandle h,
                Proc.std_err = Proc.CreatePipe
              }
        errOut <- maybe (pure "") hGetContents mErr
        _ <- evaluate (length errOut)
        code <- Proc.waitForProcess ph
        pure (code, errOut)
      -- 3. post-hook ALWAYS runs (cleanup semantics), before failure handling
      postHookResult <-
        tryEither
          $ forM_ (_backupSectionPostBackupCommand section)
          $ \hook -> runHook sshArgs ip "postBackupCommand" hook
      case fst tarResult of
        ExitFailure code ->
          throw $ OtherError $ "backup tar failed (exit " <> show code <> "): " <> cs (snd tarResult)
        ExitSuccess -> pure ()
      case postHookResult of
        Left e -> throw $ OtherError $ "postBackupCommand failed: " <> either show show e
        Right () -> pure ()
      -- 4. compress (zstd is in the service PATH via the NixOS module)
      runSubProcess_ $ cmd "zstd" & addArgs ["-q", "--rm", cs spool :: Text]
      let compressed = spool <> ".zst"
      -- 5. size cap
      size <- liftIO $ getFileSize compressed
      when (size > _backupStoreMaxSize store)
        $ throw
        $ OtherError
        $ "backup exceeds the size cap: " <> show size <> " > " <> show (_backupStoreMaxSize store)
      -- 6. content-address + upload (skip upload when the object exists)
      hash <- getFileHash compressed
      exists <- DB.backupObjectExists hash
      unless exists $ _backupStorePutFile store (backupObjectKey hash) compressed
      DB.upsertBackupObject hash (fromIntegral size)
      DB.finalizeBackupSuccess backupId hash (fromIntegral size)
      log Informational
        $ "backup " <> show backupId <> " done: " <> backupObjectKey hash <> " (" <> show size <> " bytes)"

-- | Run a hook command on the guest as root, capped at 10 minutes with the
-- guest's coreutils timeout. ssh joins its argv into one remote command
-- line, so the hook is passed shell-quoted after @sh -c@ — the remote shell
-- hands it to sh as a single word.
runHook :: [Text] -> Text -> Text -> Text -> M ()
runHook sshArgs ip label hook = do
  result <-
    tryEither
      $ runSubProcess
      $ cmd "ssh"
      & addArgs (sshArgs <> ["garnix@" <> ip, "sudo -n timeout 600 sh -c " <> shellQuote hook])
  case result of
    Left e -> throw $ OtherError $ label <> " failed: " <> either show show e
    Right () -> pure ()

-- | Single-quote a value for the guest's shell (same idiom as
-- 'Garnix.Hosting.LogStream' and 'Garnix.Build.Action' use privately).
shellQuote :: Text -> Text
shellQuote value = "'" <> T.replace "'" "'\\''" value <> "'"
