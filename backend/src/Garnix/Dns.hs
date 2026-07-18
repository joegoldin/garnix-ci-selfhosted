-- | Minimal DNS check backing the "DNS-points-here" verification of connected
-- domains (and the Servers-page (i) menu's live status).
module Garnix.Dns (resolvesToHostingIp) where

import Data.Text qualified as T
import Garnix.Monad
import Garnix.Prelude
import Network.Socket
  ( AddrInfo (addrAddress),
    SockAddr (SockAddrInet),
    defaultHints,
    getAddrInfo,
    hostAddressToTuple,
  )

-- | True iff @host@ resolves (via an A record) to the configured hosting IP —
-- used to verify a connected domain and to render a live "resolves here?"
-- status. Best-effort: returns False on any lookup failure, or when no hosting
-- IP is configured (@GARNIX_HOSTING_PUBLIC_IP@ unset).
resolvesToHostingIp :: Text -> M Bool
resolvesToHostingIp host = do
  mIp <- view #hostingPublicIp
  case mIp of
    Nothing -> pure False
    Just ip ->
      ( do
          infos <- liftIO $ getAddrInfo (Just defaultHints) (Just (T.unpack host)) Nothing
          pure $ ip `elem` catMaybes (map (ipv4Text . addrAddress) infos)
      )
        `catchAny` \_ -> pure False
  where
    ipv4Text :: SockAddr -> Maybe Text
    ipv4Text (SockAddrInet _ addr) =
      let (a, b, c, d) = hostAddressToTuple addr
       in Just (show a <> "." <> show b <> "." <> show c <> "." <> show d)
    ipv4Text _ = Nothing
