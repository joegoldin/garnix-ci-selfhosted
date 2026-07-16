-- | A 'Provisioner' implementation that provisions local microvm.nix
-- guests via the root garnix-provisionerd daemon (newline-delimited JSON over
-- a unix socket) instead of Hetzner Cloud VMs. Selected when
-- GARNIX_PROVISIONER_SOCKET is set. The int32 "hetzner id" doubles as the
-- microVM handle (guest name garnix-<id>), so the DB schema and the whole SSH
-- deploy path stay unchanged.
module Garnix.LocalProvisioner (localProvisionerInterface, exposeServer) where

import Control.Lens hiding ((.=))
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Lens (key, values, _Integer, _String)
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Lazy qualified as BSL
import Garnix.Hosting.ServerPool.Types
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBS

localProvisionerInterface :: FilePath -> Provisioner
localProvisionerInterface socketPath =
  Provisioner
    { _provisionerProvisionServer = provisionServer' socketPath,
      -- Hetzner labels are cosmetic metadata; local guests have none.
      _provisionerUpdateMetadata = \_ _ _ _ _ -> pure (),
      _provisionerDeleteServer = deleteServer' socketPath,
      _provisionerGetServerStatus = getServerStatus' socketPath
    }

provisionServer' :: FilePath -> PreprovisionedServerId -> ServerTier -> M PreprovisionedServer
provisionServer' socketPath (PreprovisionedServerId serverId) serverTier = do
  let vmId :: Int32 = fromIntegral serverId
      (vcpu, mem) = tierResources serverTier
  resp <-
    provisionerRequest socketPath
      $ object ["action" .= ("create" :: Text), "id" .= vmId, "vcpu" .= vcpu, "mem" .= mem]
  ipv4 <- case resp ^? key "ipv4" . _String of
    Just ip -> pure ip
    Nothing -> throw $ OtherError "provisioner create response is missing ipv4"
  now <- liftIO getCurrentTime
  pure
    PreprovisionedServer
      { _preprovisionedServerId = PreprovisionedServerId serverId,
        _preprovisionedServerProvisionedServerId = ProvisionedServerId vmId,
        _preprovisionedServerIpv4Addr = ipv4,
        -- Local guests are v4-only; servers.ipv6 is NOT NULL so record "".
        _preprovisionedServerIpv6Addr = "",
        _preprovisionedServerCreatedAt = now,
        _preprovisionedServerReadyAt = Nothing
      }

deleteServer' :: FilePath -> ProvisionedServerId -> M ()
deleteServer' socketPath (ProvisionedServerId vmId) =
  void
    . provisionerRequest socketPath
    $ object ["action" .= ("destroy" :: Text), "id" .= vmId]

-- | Ask the provisioner daemon to expose a guest's SSH and/or tcp ports via
-- host-port DNAT. Separate from 'provisionServer' (which stays generic) and
-- only meaningful for the local provisioner — hence not part of
-- 'Provisioner'. Response shape:
-- @{"ssh_port": Int|null, "tcp_ports": [{"guest": Int, "host": Int}, ...]}@.
exposeServer :: FilePath -> ProvisionedServerId -> Bool -> [Int] -> M ExposeResult
exposeServer socketPath (ProvisionedServerId vmId) sshExposeReq tcpGuestPorts = do
  resp <-
    provisionerRequest socketPath
      $ object
        [ "action" .= ("expose" :: Text),
          "id" .= vmId,
          "ssh_expose" .= sshExposeReq,
          "tcp_ports" .= tcpGuestPorts
        ]
  pure
    ExposeResult
      { _exposeResultSshPort = fromIntegral <$> (resp ^? key "ssh_port" . _Integer),
        _exposeResultTcpPorts =
          [ (fromIntegral g, fromIntegral h)
          | entry <- resp ^.. key "tcp_ports" . values,
            g <- toList (entry ^? key "guest" . _Integer),
            h <- toList (entry ^? key "host" . _Integer)
          ]
      }

getServerStatus' :: FilePath -> ProvisionedServerId -> M Text
getServerStatus' socketPath (ProvisionedServerId vmId) = do
  resp <-
    provisionerRequest socketPath
      $ object ["action" .= ("status" :: Text), "id" .= vmId]
  case resp ^? key "status" . _String of
    Just status -> pure status
    Nothing -> throw $ OtherError "provisioner status response is missing status"

-- | One request/response over the daemon socket (newline-delimited JSON, one
-- request per connection). Daemon errors come back as {"error": "..."}.
provisionerRequest :: FilePath -> Aeson.Value -> M Aeson.Value
provisionerRequest socketPath payload = do
  raw <- liftIO $ do
    sock <- Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol
    Socket.connect sock (Socket.SockAddrUnix socketPath)
    SocketBS.sendAll sock (BSL.toStrict (Aeson.encode payload) <> "\n")
    let loop acc = do
          chunk <- SocketBS.recv sock 65536
          if BSC.null chunk || BSC.elem '\n' chunk
            then pure (acc <> chunk)
            else loop (acc <> chunk)
    resp <- loop ""
    Socket.close sock
    pure resp
  resp <- case Aeson.eitherDecodeStrict (BSC.takeWhile (/= '\n') raw) of
    Left decodeError -> throw $ OtherError $ "provisioner response decode: " <> cs decodeError
    Right v -> pure (v :: Aeson.Value)
  case resp ^? key "error" . _String of
    Just daemonError -> throw $ OtherError $ "provisioner: " <> daemonError
    Nothing -> pure resp
