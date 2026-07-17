-- | A 'Provisioner' implementation for tests: instead of talking to a
-- garnix-provisionerd daemon, it boots a real (self-contained) qemu NixOS VM
-- per provisioned server so the SSH-based deploy path exercised by the pool
-- and hosting specs has something real to connect to. Provisioned servers are
-- tracked in a global in-memory state map keyed by 'ProvisionedServerId'.
module Garnix.TestHelpers.ProvisionerMock
  ( ProvisionerState (ProvisionerState),
    testProvisioner,
    provisionerMockState,
    _getProvisionerState,
    deleteContainer,
    Thread (..),
  )
where

import Control.Concurrent hiding (killThread)
import Control.Exception (throwIO)
import Control.Exception.Safe qualified
import Cradle
import Data.Aeson.Lens
import Data.Map qualified as Map
import Data.String.Interpolate (i)
import Data.Text.IO qualified as T
import Garnix.Hosting.ServerPool.Types ()
import Garnix.Monad
import Garnix.NixConfig (nixConfDefaults)
import Garnix.Prelude
import Garnix.Types
import Network.Socket.Free (getFreePort)
import System.Directory (copyFile)
import System.Environment
import System.IO (hGetLine)
import System.IO.Temp
import System.IO.Unsafe (unsafePerformIO)
import System.Process qualified as Proc
import System.Random (randomIO)

testProvisioner :: Provisioner
testProvisioner =
  Provisioner
    { _provisionerProvisionServer = \serverId _serverTier -> do
        now <- liftIO getCurrentTime
        provisionedServerId' <- liftIO $ ProvisionedServerId <$> randomIO
        (ipAddr, containerId, mvar) <- liftIO runContainer
        let info =
              PreprovisionedServer
                { _preprovisionedServerId = serverId,
                  _preprovisionedServerProvisionedServerId = provisionedServerId',
                  _preprovisionedServerCreatedAt = now,
                  _preprovisionedServerIpv4Addr = ipAddr,
                  _preprovisionedServerIpv6Addr = "<no ipv6>",
                  _preprovisionedServerReadyAt = Nothing
                }
        liftIO $ modifyMVar_ (_getProvisionerState provisionerMockState) (pure . Map.insert provisionedServerId' (containerId, Left info, mvar))
        return info,
      _provisionerUpdateMetadata = \_repoInfo deploymentType build serverId provisionedServerId -> do
        now <- liftIO getCurrentTime
        let upd x = case x of
              Nothing -> error "Updating non-existent server"
              (Just (_, Right _, _)) -> error "not used"
              (Just (t, Left p, mv)) ->
                let s =
                      ServerInfo
                        { _serverInfoId = serverId,
                          _serverInfoProvisionedServerId = provisionedServerId,
                          _serverInfoIpv4Addr = p ^. ipv4Addr,
                          _serverInfoIpv6Addr = p ^. ipv6Addr,
                          _serverInfoCreatedAt = now,
                          _serverInfoEndedAt = Nothing,
                          _serverInfoConfigurationBuildId = build ^. id,
                          _serverInfoPullRequest = ghPrDeployment deploymentType,
                          _serverInfoReadyAt = Nothing,
                          _serverInfoBuildPersistenceName = Nothing,
                          _serverInfoTier = def,
                          _serverInfoIsPrimary = False
                        }
                 in Just (t, Right s, mv)
        liftIO $ modifyMVar_ (_getProvisionerState provisionerMockState) $ \m -> pure $ Map.alter upd provisionedServerId m,
      _provisionerDeleteServer = \provisionedServerId -> liftIO $ do
        let upd = \case
              Nothing -> pure Nothing
              Just (thread, _, _) -> deleteContainer thread $> Nothing
        modifyMVar_ (_getProvisionerState provisionerMockState) (Map.alterF upd provisionedServerId),
      _provisionerGetServerStatus = \provisionedServerId -> do
        m <- liftIO $ readMVar (_getProvisionerState provisionerMockState)
        case Map.lookup provisionedServerId m of
          Nothing -> throw $ ProvisioningError "No such server"
          Just (_, _, mvar) -> liftIO $ readMVar mvar
    }

newtype ProvisionerState = ProvisionerState
  { _getProvisionerState ::
      MVar
        ( Map.Map
            ProvisionedServerId
            (Thread, Either PreprovisionedServer ServerInfo, MVar Text)
        )
  }

data Thread = Thread
  { threadId :: ThreadId,
    joinThread :: IO ()
  }

forkThread :: IO () -> IO Thread
forkThread action = do
  waiter <- newEmptyMVar
  threadId <- forkIO $ action `finally` putMVar waiter ()
  pure $ Thread {threadId, joinThread = readMVar waiter}

{-# NOINLINE provisionerMockState #-}
provisionerMockState :: ProvisionerState
provisionerMockState = unsafePerformIO $ ProvisionerState <$> newMVar mempty

runContainer :: (HasCallStack) => IO (Text, Thread, MVar Text)
runContainer = do
  mvar <- newMVar "initializing"
  port <- getFreePort
  let markDead = modifyMVar_ mvar (\_ -> pure "stopped")
  thread <- forkThread $ flip finally markDead $ do
    withSystemTempDirectory "garnix-vm" $ \dir -> do
      bin <- getVmScript
      parentEnv <- getEnvironment
      void
        $ Proc.withCreateProcess
          ( (Proc.proc bin [])
              { Proc.cwd = Just dir,
                Proc.std_in = Proc.CreatePipe,
                Proc.std_out = Proc.CreatePipe,
                Proc.std_err = Proc.CreatePipe,
                Proc.env =
                  Just
                    $ parentEnv
                    ++ [ ( "QEMU_NET_OPTS",
                           "hostfwd=tcp::" <> cs (show port) <> "-:22"
                         ),
                         ("TMPDIR", dir)
                       ]
              }
          )
        $ \_min mout merr ph -> case (mout, merr) of
          (Just out, Just err) -> do
            void $ forkIO $ do
              stderr <- T.hGetContents err
              exitCode <- Proc.waitForProcess ph
              case exitCode of
                ExitFailure exitCode -> do
                  T.putStrLn $ "qemu process failed (" <> show exitCode <> "):\n" <> stderr
                ExitSuccess -> pure ()
            let loop = do
                  ln <- hGetLine out
                  if "Welcome to NixOS" `isInfixOf` ln
                    then do
                      modifyMVar_ mvar (const $ pure "running")
                      void $ Proc.waitForProcess ph
                      modifyMVar_ mvar (const $ pure "stopped")
                    else loop
             in loop
          _ -> error "Can't read std streams of VM"
  pure ("localhost:" <> show port, thread, mvar)

deleteContainer :: Thread -> IO ()
deleteContainer Thread {threadId, joinThread} = do
  killThread threadId
  joinThread

getVmScript :: IO FilePath
getVmScript = do
  result <- modifyMVar __vmScriptCache $ \case
    Just cached -> pure (Just cached, cached)
    Nothing -> do
      result <- Control.Exception.Safe.try uncachedGetVmScript
      pure (Just result, result)
  case result of
    Right vmScript -> pure vmScript
    Left e -> throwIO e

{-# NOINLINE __vmScriptCache #-}
__vmScriptCache :: MVar (Maybe (Either SomeException FilePath))
__vmScriptCache = System.IO.Unsafe.unsafePerformIO $ newMVar Nothing

uncachedGetVmScript :: IO FilePath
uncachedGetVmScript = do
  withSystemTempDirectory "garnix-vm" $ \dir -> do
    writeFile (dir </> "flake.nix") provisionerMockNixosConfig
    -- Reusing the top-level flake file can substantially speed up tests.
    copyFile "../flake.lock" (dir </> "flake.lock")
    StdoutUntrimmed result <-
      run
        $ cmd "nix"
        & setWorkingDir dir
        & addArgs
          [ "build",
            ".#nixosConfigurations.provisioner-mock.config.system.build.vm",
            "--json",
            "--no-link" :: String
          ]
        & nixConfDefaults
        & silenceStderr
    let !bin = case result ^? nth 0 . key "outputs" . key "out" . _String of
          Nothing ->
            error
              $ "Could not get 'outputs' of provisioner-mock VM in "
              <> show result
          Just o -> cs o </> "bin/run-provisioner-mock-vm"
    pure bin

provisionerMockNixosConfig :: String
provisionerMockNixosConfig =
  [i|
      {
        # If you update this, update also places where it matches.
        # Search for INNER_NIXPKGS_MATCHES
        inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11-small";

        outputs = { self, nixpkgs} :
          let system = "x86_64-linux";
              pkgs = nixpkgs.legacyPackages."${system}";
          in
          {
            nixosConfigurations.provisioner-mock = nixpkgs.lib.nixosSystem {
              system = "x86_64-linux";
              modules = [
                "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
                { nixpkgs = { inherit pkgs; };}
                ({ ... }: {
                  system.configurationRevision = nixpkgs.lib.mkIf (self ? rev) self.rev;
                  documentation.man.enable = false;
                  documentation.info.enable = false;
                  boot.kernelParams = [ "console=tty1" "console=ttyS0" ];
                  services.openssh.enable = true;
                  networking.hostName = "provisioner-mock";
                  networking.firewall.enable = false;
                  virtualisation.graphics = false;
                  virtualisation.diskSize = 5000;
                  virtualisation.writableStoreUseTmpfs = false;
                  virtualisation.useNixStoreImage = true;
                  virtualisation.writableStore = true;
                  users.extraUsers.root.password = "";
                  users.users.root = {
                    openssh.authorizedKeys.keys = [
                       "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC2sZYF9l/ssO+uk5bdaZLskJKxNFbbJDd3cR1TR17KE1elmC4KQ7LOU3329JMyiDU73DlUHRG+1zhN9I6UNCJR8en7YDPWODw+1eKAFI1IQiYuuvp3rO9RnR5DYXxzGjEBuxxxOqLRCLmaWsP4nQ6kzmmWvIYZ9npNLCp1KN42EcCzlpUR4NOqxJr834vkqlgk3dnl00wYlLO5v4+t0l48SrcUL8EM7z/i0ivjT/15sl6PgNSgTGbB6eIWg9oLt76rhXpGvvccCp/atDb98+OXlPpDw90MgO0sGA8UyAFAKrpoLaNTPFyRrCBlHLIBlvgagNaYoq6DOGJVOGK227tJMiwDnhUyOirutYnIJ6MNdUGmq2bF7nX15uXGmGKfHf4TaShgMCcitlsrzVwuO/gdce1Y5TnJc/Wdbj3D8j95/41bBp6MyRlUK5gpT0R+NSX1hv0rL+eSa56REwfcZMrYWFr3Hpv7eq9VHAS0NBj+Hy5N9JCc+mvB7w2XufNoMkk= jkarni@janus"
                    ];
                  };
                })
              ];
            };
          };
      }
   |]
