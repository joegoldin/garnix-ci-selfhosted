module Garnix.Hosting.ServerPoolSpec (spec) where

import Control.Lens
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

    it "recreates servers if some are used up @slow" $ do
      withServerPoolM $ do
        build <-
          testBuild
            $ (branch ?~ "main")
            . (repoUser .~ "owner")
            . (repoName .~ "repo")
        server <- createServer defaultRepoInfo (BranchDeployment "main") (ServerToSpinUp I16x32 build False False False False [] [] [] [] Nothing)
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
                  _serverInfoProvisionedServerId = ProvisionedServerId 20950838,
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
