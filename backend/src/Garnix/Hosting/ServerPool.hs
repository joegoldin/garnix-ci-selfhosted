module Garnix.Hosting.ServerPool
  ( createServer,
    initializeProvisioningPool,
    sshArgsFor,
    _checkServerPoolInterval,
  )
where

import Cradle
import Data.Text qualified as T
import Garnix.DB qualified as DB
import Garnix.Duration
import Garnix.Hosting.ServerPool.Types ()
import Garnix.Monad
import Garnix.Monad.Async (timeoutThrowing)
import Garnix.Monad.NoThrow qualified as NoThrow
import Garnix.Monad.SubProcess (runSubProcess_)
import Garnix.Monad.SubProcess.Deprecated qualified as Deprecated
import Garnix.Prelude
import Garnix.Types

createServer :: RepoInfo -> DeploymentType -> ServerToSpinUp -> M ServerInfo
createServer repoInfo deployType serverToSpinUp = do
  startedCreating <- liftIO getCurrentTime
  let pollForServer = do
        res <- DB.claimServerDB serverToSpinUp (ghPrDeployment deployType)
        case res of
          Just r -> pure r
          Nothing -> do
            now <- liftIO getCurrentTime
            when (now > addTime serverWaitTimeout startedCreating)
              $ throw
              $ ProvisioningError "Waited too long for server provisioning. Cancelled"
            log Informational "createServer: no server ready, waiting..."
            threadDelay pollForServerDuration
            pollForServer
  server <- pollForServer
  log Informational $ "createServer: got server" <> show (server ^. id)
  (ip, sshArgs) <- sshArgsFor server
  void
    ( Deprecated.runProc
        "ssh"
        ( sshArgs
            <> [ "root@" <> ip,
                 "ls"
               ]
        )
        []
    )
  updateMetadata repoInfo deployType (serverToSpinUp ^. #build) (server ^. id) (server ^. provisionedServerId)
  pure server

initializeProvisioningPool :: M ThreadId
initializeProvisioningPool = withTextSpan ("tag", "provisioning pool thread") $ do
  NoThrow.forkForever _checkServerPoolInterval $ do
    -- Self-heal: drop rows whose provisioning died before readiness, so they
    -- stop counting toward the pool (a wedged row otherwise blocks refills
    -- forever while claims time out).
    stale <- DB.deleteStaleUnreadyPoolRows
    when (stale > 0)
      $ log Warning
      $ "Removed " <> show stale <> " stale unready server-pool rows (provisioning died before readiness)."
    serverPoolConfig <- view #serverPoolConfig
    NoThrow.forConcurrently_ serverPoolConfig $ \(serverTier, idealPoolSize) -> do
      withSpan serverTier $ do
        count <- DB.getPreprovisionedServerCount serverTier
        log Informational $ "Currently provisioned " <> show serverTier <> " servers: " <> show count
        let missingFromPool = idealPoolSize - fromIntegral count
        when (missingFromPool > 0) $ do
          let toProvision = min missingFromPool maxNumberOfProvisioningThreads
          log Informational $ "Will preprovision " <> show toProvision <> " more " <> show serverTier <> " servers. " <> show missingFromPool <> " total servers needed."
          NoThrow.replicateConcurrently_ toProvision $ do
            id' <- DB.newServerInPool serverTier
            ( do
                server <- provisionServer id' serverTier <?> ("Preprovisioning server " <> show id')
                DB.updatePreprovisionedServer server
                setupServer server
                DB.setPreprovisionedReady (server ^. id)
              )
              `onError` DB.deleteServerFromPool id'

setupServer :: PreprovisionedServer -> M ()
setupServer preprovisionedServer = do
  isInitialized <-
    waitTillServerIsInitialized (preprovisionedServer ^. provisionedServerId)
      <?> "Waiting for server to be initialized"
  unless isInitialized
    . throw
    . ProvisioningError
    $ "Server did not reach 'running' status in given time limit. Server info:"
    <> show preprovisionedServer
  isNixos <- waitTillServerIsNixos preprovisionedServer <?> "Waiting for NixOS to be installed on server"
  unless isNixos
    . throw
    . ProvisioningError
    $ "Server did not become NixOS in given time limit. Server info:"
    <> show preprovisionedServer
  return ()

waitTillServerIsInitialized :: ProvisionedServerId -> M Bool
waitTillServerIsInitialized = mockable #waitTillServerIsInitializedMock $ loop 100
  where
    delay :: Duration
    delay = fromSeconds @Int 1

    loop :: Int -> ProvisionedServerId -> M Bool
    loop n hId
      | n <= 0 = pure False
      | otherwise = do
          getServerStatus hId >>= \case
            "running" -> pure True
            _ -> liftIO (threadDelay delay) >> loop (n - 1) hId

waitTillServerIsNixos :: PreprovisionedServer -> M Bool
waitTillServerIsNixos server = isNixos 40
  where
    delay :: Duration
    delay = fromSeconds @Int 20

    isNixos :: Int -> M Bool
    isNixos 0 = pure False
    isNixos n = do
      (ip, sshArgs) <- sshArgsFor server
      let again = liftIO (threadDelay delay) >> isNixos (n - 1)
      ( do
          timeoutThrowing (fromMinutes @Int 1) (SshTimeout {command = "nixos-version"}) $ do
            runSubProcess_
              ( cmd "ssh"
                  & addArgs (sshArgs <> ["root@" <> ip, "nixos-version"])
              )
          pure True
        )
        -- These errors happen when a connection can't be established
        `catchAny` const again
        -- These errors happen when nixos-version isn't present
        `catchError` const again

maxNumberOfProvisioningThreads :: Int
maxNumberOfProvisioningThreads = 10

serverWaitTimeout :: Duration
serverWaitTimeout = fromMinutes @Int 10

_checkServerPoolInterval :: Duration
_checkServerPoolInterval = fromSeconds @Int 15

pollForServerDuration :: Duration
pollForServerDuration = fromSeconds @Int 5

sshArgsFor :: (HasIpv4Addr s Text) => s -> M (Text, [Text])
sshArgsFor server = do
  keyFiles <- view #sshUserHostingKeys
  let sshKeysParameters = concatMap (\f -> ["-i", cs f]) keyFiles
  (ip, port) <- splitPortFromIP (server ^. ipv4Addr)
  pure
    ( ip,
      sshKeysParameters
        <> [ "-o",
             "BatchMode=yes",
             "-o",
             "StrictHostKeychecking=no",
             "-o",
             "UserKnownHostsFile=/dev/null",
             "-o",
             "ConnectTimeout=15",
             "-p",
             port
           ]
    )

splitPortFromIP :: Text -> M (Text, Text)
splitPortFromIP ip = case T.splitOn ":" ip of
  [_] -> pure (ip, "22")
  [ip', p] -> pure (ip', p)
  _ -> throw $ ProvisioningError ("IP not valid: " <> ip)
