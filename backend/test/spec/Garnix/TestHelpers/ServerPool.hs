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
import Garnix.TestHelpers.HetznerMock (deleteContainer, hetznerState, _getHetznerState)
import Garnix.TestHelpers.Monad (cleanDbConn, withTestEnvironment)
import System.Directory (canonicalizePath)
import System.Environment (setEnv)
import System.IO.Temp (withSystemTempDirectory)

testPoolConfig :: [(ServerTier, Int)]
testPoolConfig =
  [ (I2x4, 4),
    (I4x8, 1),
    (I8x16, 0),
    (I16x32, 0)
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
        (_getHetznerState hetznerState)
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
        (_getHetznerState hetznerState)
        ( Map.traverseMaybeWithKey
            (\_ (threadId, _, _) -> deleteContainer threadId $> Nothing)
        )

stopActiveServers :: IO ()
stopActiveServers =
  liftIO
    $ MVar.modifyMVar_
      (_getHetznerState hetznerState)
      ( Map.traverseMaybeWithKey
          ( \_ val@(threadId, serverStatus, _) ->
              case serverStatus of
                Left _provisioned -> pure $ Just val
                Right _runningServer -> deleteContainer threadId $> Nothing
          )
      )
