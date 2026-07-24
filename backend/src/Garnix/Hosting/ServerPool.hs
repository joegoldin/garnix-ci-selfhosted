module Garnix.Hosting.ServerPool
  ( createServer,
    initializeProvisioningPool,
    sshArgsFor,
    sshArgsForAddress,
    _checkServerPoolInterval,
  )
where

import Cradle
import Data.Text qualified as T
import Garnix.DB qualified as DB
import Garnix.Duration
import Garnix.Hosting.ServerPool.Types
import Garnix.Monad
import Garnix.Monad.Async (timeoutThrowing)
import Garnix.Monad.NoThrow qualified as NoThrow
import Garnix.Monad.SubProcess (runSubProcess_)
import Garnix.Monad.SubProcess.Deprecated qualified as Deprecated
import Garnix.Prelude
import Garnix.Types

-- | @report@ surfaces the live phase (provisioning / evicting / queuing) to the
-- deployment run so the UI shows what a deploy is actually waiting on, instead
-- of an opaque Pending. It is deduped against the previous phase so the 5s
-- budget-queue poll doesn't spam the log.
createServer :: (Text -> M ()) -> RepoInfo -> DeploymentType -> ServerToSpinUp -> M ServerInfo
createServer report repoInfo deployType serverToSpinUp = do
  budget <- hostingBudget
  let tier = serverToSpinUp ^. #serverTier
      reportPhase lastReport msg
        | lastReport == Just msg = pure lastReport
        | otherwise = report msg >> pure (Just msg)
      pollForServer lastReport = do
        res <- DB.claimServerDB serverToSpinUp (ghPrDeployment deployType)
        case res of
          Just r -> pure r
          Nothing ->
            -- No warm VM of the requested tier. Decide elastically rather than
            -- just waiting for the static refill (which only tops up
            -- configured tiers — an unlisted tier would otherwise never come).
            DB.committedResources >>= \committed ->
              if fitsBudget budget committed tier
                then do
                  -- Budget has room: provision one of this tier now, then
                  -- re-claim it. (A stuck provision throws via provisionOne's
                  -- own readiness timeouts, failing the deploy — it does not
                  -- hang here.)
                  log Informational $ "createServer: no ready " <> show tier <> ", provisioning one on demand"
                  lr <- reportPhase lastReport $ "No warm " <> serverTierToText tier <> " guest ready — provisioning one on demand (a fresh boot can take a couple of minutes)…"
                  provisionOne tier
                  pollForServer lr
                else
                  DB.claimIdleReadyPoolVMForEviction >>= \case
                    Just (victimId, victimTier) -> do
                      -- At the budget but an idle warm VM of some tier exists:
                      -- reclaim it for the tier this deploy actually needs.
                      log Informational $ "createServer: evicting idle pooled " <> show victimTier <> " to free budget for " <> show tier
                      lr <- reportPhase lastReport $ "At the hosting budget — freeing an idle " <> serverTierToText victimTier <> " guest to make room for a " <> serverTierToText tier <> "…"
                      bestEffortDeleteGuest victimId
                      pollForServer lr
                    Nothing -> do
                      -- Budget full and nothing idle to evict: queue. The
                      -- deploy stays Pending (no hard timeout — this is the
                      -- intended back-pressure) until a running server frees
                      -- resources.
                      log Informational $ "createServer: at hosting budget for " <> show tier <> " (committed=" <> show committed <> " cap=" <> show budget <> "); queuing until resources free"
                      lr <- reportPhase lastReport "At the hosting RAM/CPU budget — queuing until running servers free resources…"
                      threadDelay pollForServerDuration
                      pollForServer lr
  server <- pollForServer Nothing
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

-- | The resolved hosting budget (Nothing dims = unbounded) from the reader env.
hostingBudget :: M ResourceBudget
hostingBudget =
  ResourceBudget <$> view #hostingVcpuBudget <*> view #hostingMemBudgetMiB

-- | Provision one warm guest of a tier into the pool: insert the row, boot +
-- initialise the guest, mark it ready. Cleans up the guest and/or its row on
-- any failure and re-raises (callers under 'NoThrow' swallow it; 'createServer'
-- lets it fail the deploy).
provisionOne :: ServerTier -> M ()
provisionOne serverTier = do
  id' <- DB.newServerInPool serverTier
  ( do
      server <- provisionServer id' serverTier <?> ("Preprovisioning server " <> show id')
      DB.updatePreprovisionedServer server
      ( do
          setupServer server
          DB.setPreprovisionedReady (server ^. id)
        )
        -- If the server never becomes ready, destroy the guest as well:
        -- deleting only the pool row leaks the provisioned VM (it keeps
        -- running with no record of it), and the refill loop then boots a
        -- replacement every interval — a VM storm under any persistent
        -- provisioning failure.
        `onError` bestEffortDeleteGuest (server ^. provisionedServerId)
    )
    `onError` DB.deleteServerFromPool id'

-- | Best-effort teardown of a guest whose pool lifecycle failed, or that we are
-- evicting to reclaim budget for another tier. Never throws.
bestEffortDeleteGuest :: ProvisionedServerId -> M ()
bestEffortDeleteGuest provisionedId =
  deleteServer provisionedId
    `catchAny` (\e -> log Warning $ "Failed to delete pooled guest: " <> show e)
    `catchError` (\e -> log Warning $ "Failed to delete pooled guest: " <> show e)

initializeProvisioningPool :: M ThreadId
initializeProvisioningPool = withTextSpan ("tag", "provisioning pool thread") $ do
  NoThrow.forkForever _checkServerPoolInterval $ do
    -- Self-heal: drop rows whose provisioning died before readiness, so they
    -- stop counting toward the pool (a wedged row otherwise blocks refills
    -- forever while claims time out).
    stale <- DB.deleteStaleUnreadyPoolRows
    when (stale > 0)
      $ log Warning
      $ "Removed "
      <> show stale
      <> " stale unready server-pool rows (provisioning died before readiness)."
    serverPoolConfig <- view #serverPoolConfig
    budget <- hostingBudget
    NoThrow.forConcurrently_ serverPoolConfig $ \(serverTier, idealPoolSize) -> do
      withSpan serverTier $ do
        count <- DB.getPreprovisionedServerCount serverTier
        log Informational $ "Currently provisioned " <> show serverTier <> " servers: " <> show count
        let missingFromPool = idealPoolSize - fromIntegral count
        when (missingFromPool > 0) $ do
          let toProvision = min missingFromPool maxNumberOfProvisioningThreads
          log Informational $ "Will preprovision up to " <> show toProvision <> " more " <> show serverTier <> " servers. " <> show missingFromPool <> " total servers wanted."
          NoThrow.replicateConcurrently_ toProvision $ do
            -- Keep-warm only within budget. Concurrent checks can transiently
            -- overshoot by a VM; the configured reserve absorbs that.
            committed <- DB.committedResources
            if fitsBudget budget committed serverTier
              then provisionOne serverTier
              else
                log Informational
                  $ "Not warming "
                  <> show serverTier
                  <> ": at hosting budget (committed="
                  <> show committed
                  <> " cap="
                  <> show budget
                  <> ")"

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

_checkServerPoolInterval :: Duration
_checkServerPoolInterval = fromSeconds @Int 15

pollForServerDuration :: Duration
pollForServerDuration = fromSeconds @Int 5

sshArgsFor :: (HasIpv4Addr s Text) => s -> M (Text, [Text])
sshArgsFor server = sshArgsForAddress (server ^. ipv4Addr)

sshArgsForAddress :: Text -> M (Text, [Text])
sshArgsForAddress address = do
  keyFiles <- view #sshUserHostingKeys
  let sshKeysParameters = concatMap (\f -> ["-i", cs f]) keyFiles
  (ip, port) <- splitPortFromIP address
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
