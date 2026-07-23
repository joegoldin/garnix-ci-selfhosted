module Garnix.TestHelpers.ServerPool where

import Control.Concurrent.MVar qualified as MVar
import Control.Exception.Lifted qualified as Lifted
import Control.Exception.Safe qualified as Safe
import Data.Map.Strict qualified as Map
import Database.PostgreSQL.Typed (pgSQL)
import Garnix.DB qualified as DB
import Garnix.Hosting.ServerPool qualified as ServerPool
import Garnix.Hosting.ServerPool.Types
import Garnix.Monad (M, runM)
import Garnix.Prelude
import Garnix.TestHelpers.ProvisionerMock (deleteContainer, provisionerMockState, _getProvisionerState)
import Garnix.TestHelpers.Monad (cleanDbConn, withTestEnvironment)
import System.Directory (canonicalizePath)
import System.Environment (setEnv)
import System.IO.Temp (withSystemTempDirectory)

-- | Every pooled server is a real qemu VM (see 'ProvisionerMock'), so keep
-- this minimal. I1x2 is the default `deployment.machine` tier and the only
-- one DeploySpec's configs request (claimServerDB matches tiers exactly), so
-- pre-warm that exact tier: otherwise each deploy provisions its own I1x2 on
-- demand instead of claiming a ready one, changing what the specs observe.
-- Two, because "deletes old servers" holds gen-1 while deploying gen-2.
testPoolConfig :: [(ServerTier, Int)]
testPoolConfig =
  [ (I1x2, 2)
  ]

withServerPool :: IO a -> IO a
withServerPool action =
  withSystemTempDirectory "withServerPool" $ \tmp -> do
    withTestEnvironment tmp $ \env -> do
      Safe.bracket
        (setup env)
        (tearDown env)
        (const action)
  where
    setup env = do
      sshKey <- canonicalizePath "ssh-key-for-tests"
      setEnv "GARNIX_SERVER_SSH_KEYS" sshKey
      runM env $ do
        void $ DB.pgExec [pgSQL| TRUNCATE server_pool |]
        local (#serverPoolConfig .~ testPoolConfig) $ do
          ServerPool.initializeProvisioningPool

    tearDown env tid = do
      mapM_ killThread tid
      MVar.modifyMVar_
        (_getProvisionerState provisionerMockState)
        ( Map.traverseMaybeWithKey
            (\_ (threadId, _, _) -> deleteContainer threadId $> Nothing)
        )
      withSystemTempDirectory "truncateDB" $ \tmp -> do
        withTestEnvironment tmp $ \env ->
          void $ runM env $ do
            DB.pgExec [pgSQL| TRUNCATE server_pool |]
      cleanDbConn env

withServerPoolM :: M a -> M a
withServerPoolM action =
  Lifted.bracket setup tearDown $ const action
  where
    setup :: M ThreadId
    setup = do
      void $ DB.pgExec [pgSQL| TRUNCATE server_pool |]
      ServerPool.initializeProvisioningPool

    tearDown :: ThreadId -> M ()
    tearDown tid = liftIO $ do
      killThread tid
      MVar.modifyMVar_
        (_getProvisionerState provisionerMockState)
        ( Map.traverseMaybeWithKey
            (\_ (threadId, _, _) -> deleteContainer threadId $> Nothing)
        )

stopActiveServers :: IO ()
stopActiveServers =
  liftIO
    $ MVar.modifyMVar_
      (_getProvisionerState provisionerMockState)
      ( Map.traverseMaybeWithKey
          ( \_ val@(threadId, serverStatus, _) ->
              case serverStatus of
                Left _provisioned -> pure $ Just val
                Right _runningServer -> deleteContainer threadId $> Nothing
          )
      )
