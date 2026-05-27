module Garnix.Hosting.ServerPoolSpec (spec) where

import Control.Concurrent.MVar.Lifted
import Control.Lens
import Data.List.Extra (enumerate)
import Database.PostgreSQL.Typed (pgSQL)
import Garnix.DB qualified as DB
import Garnix.Duration
import Garnix.Hosting.ServerPool
import Garnix.Hosting.ServerPool.Types
import Garnix.Monad
import Garnix.Prelude
import Garnix.TestHelpers
import Garnix.TestHelpers.Monad
import Garnix.TestHelpers.ServerPool (withServerPoolM)
import Garnix.Types
import Test.Hspec

spec :: Spec
spec = inM $ beforeM_ truncateDBM $ aroundM_ (suppressLogsWhenPassing . local (#serverPoolConfig .~ testPoolConfig)) $ do
  describe "initializeProvisioningPool" $ do
    it "initially creates as many servers as configured" $ do
      withServerPoolM $ do
        waitFor (fromSeconds @Int 1) $ do
          servers :: [ServerTier] <- DB.pgQuery [pgSQL| SELECT server_tier FROM server_pool |]
          sort servers `shouldBeM` sort (concatMap (\(tier, n) -> replicate n tier) testPoolConfig)

    it "tries other locations if provisioning fails" $ do
      mvar <- newMVar (0, False)
      let f = hetznerInterfaceModifyProvisionServer $ \provision -> do
            join $ modifyMVar mvar $ \(servers, hasFailed) ->
              pure
                $ if not hasFailed
                  then ((servers, True), throw $ OtherError "retry")
                  else ((succ servers, hasFailed), provision)
      local f $ do
        withServerPoolM $ do
          waitFor (fromSeconds @Int 1) $ do
            poolSize <- getPoolSize
            (servers, _) <- readMVar mvar
            servers `shouldBeM` poolSize

    it "provisions servers of all types in all configured locations" $ do
      let expectedRetries :: [(HetznerLocation, HetznerServerType)] =
            flip concatMap testPoolConfig $ \(tier, poolSize) ->
              flip concatMap (serverTierToHetznerServerType tier) $ \hetznerServerType ->
                flip concatMap (enumerate @HetznerLocation) $ \location ->
                  replicate poolSize (location, hetznerServerType)
      mvar <- newMVar []
      let f = hetznerInterfaceModifyProvisionServerWithParams $ \id loc typ provision -> do
            size <- modifyMVar mvar (\xs -> pure (xs <> [(loc, typ)], length xs + 1))
            if size == length expectedRetries
              then do
                provision id loc typ
              else throw $ OtherError "retry"
      local f $ do
        withServerPoolM $ do
          waitFor (fromSeconds @Int 1) $ do
            result <- readMVar mvar
            sort result `shouldBeM` sort expectedRetries

    it "tries cheaper servers first" $ do
      let expectedRetries :: [(HetznerLocation, HetznerServerType)] =
            flip concatMap [(I2x4, 1)] $ \(tier, poolSize) ->
              flip concatMap (serverTierToHetznerServerType tier) $ \hetznerServerType ->
                flip concatMap (enumerate @HetznerLocation) $ \location ->
                  replicate poolSize (location, hetznerServerType)
      local (#serverPoolConfig .~ [(I2x4, 1)]) $ do
        mvar <- newMVar []
        let f = hetznerInterfaceModifyProvisionServerWithParams $ \id loc typ provision -> do
              size <- modifyMVar mvar (\xs -> pure (xs <> [(loc, typ)], length xs + 1))
              if size == length expectedRetries
                then do
                  provision id loc typ
                else throw $ OtherError "retry"
        local f $ do
          withServerPoolM $ do
            waitFor (fromSeconds @Int 1) $ do
              result <- readMVar mvar
              result `shouldBeM` expectedRetries

    it "recreates servers if some are used up @slow" $ do
      withServerPoolM $ do
        build <-
          testBuild
            $ (branch ?~ "main")
            . (repoUser .~ "owner")
            . (repoName .~ "repo")
        server <- createServer defaultRepoInfo (BranchDeployment "main") (ServerToSpinUp I16x32 build False)
        server ^. tier `shouldBeM` I16x32
        running <- DB.getRunningServersOf defaultRepoInfo (BranchDeployment "main")
        fromSingleton running ^. tier `shouldBeM` I16x32
        waitFor (fromSeconds @Int 20) $ do
          log Informational "waiting for pool to grow..."
          servers :: [Maybe Int64] <- DB.pgQuery [pgSQL| SELECT COUNT(*) FROM server_pool |]
          poolSize <- getPoolSize
          servers `shouldBeM` [Just $ fromIntegral poolSize]

    describe "sshArgsFor" $ do
      it "returns the correct IP and SSH arguments for multiple hosting keys" $ do
        let server =
              ServerInfo
                { _serverInfoId = ServerId $ 1 ^. from hashIdInt,
                  _serverInfoHetznerServerId = HetznerServerId 20950838,
                  _serverInfoIpv4Addr = "1.2.3.4",
                  _serverInfoIpv6Addr = "<none>",
                  _serverInfoCreatedAt = error "not used",
                  _serverInfoEndedAt = Nothing,
                  _serverInfoConfigurationBuildId = BuildId $ 123 ^. from hashIdInt,
                  _serverInfoPullRequest = Nothing,
                  _serverInfoReadyAt = Nothing,
                  _serverInfoBuildPersistenceName = Nothing,
                  _serverInfoTier = def,
                  _serverInfoIsPrimary = False
                }
        local (#sshUserHostingKeys .~ ["/key1", "/key2"]) $ do
          (ip, sshArgs) <- sshArgsFor server
          ip `shouldBeM` "1.2.3.4"
          sshArgs `shouldContainM` ["-i", "/key1", "-i", "/key2"]

testPoolConfig :: [(ServerTier, Int)]
testPoolConfig =
  [ (I2x4, 2),
    (I4x8, 1),
    (I8x16, 1),
    (I16x32, 1)
  ]

getPoolSize :: M Int
getPoolSize = do
  view #serverPoolConfig
    <&> sum . map snd

hetznerInterfaceModifyProvisionServer :: (M PreprovisionedServer -> M PreprovisionedServer) -> Env -> Env
hetznerInterfaceModifyProvisionServer f env =
  env
    & #hetznerInterface %~ \i ->
      i
        { _hetznerInterfaceProvisionServer = \x loc typ -> do
            f $ _hetznerInterfaceProvisionServer i x loc typ
        }

type ProvisionServerType = (PreprovisionedServerId -> HetznerLocation -> HetznerServerType -> M PreprovisionedServer)

hetznerInterfaceModifyProvisionServerWithParams :: (PreprovisionedServerId -> HetznerLocation -> HetznerServerType -> ProvisionServerType -> M PreprovisionedServer) -> Env -> Env
hetznerInterfaceModifyProvisionServerWithParams f env =
  env
    & #hetznerInterface %~ \i ->
      i
        { _hetznerInterfaceProvisionServer = \x loc typ -> do
            f x loc typ (_hetznerInterfaceProvisionServer i)
        }
