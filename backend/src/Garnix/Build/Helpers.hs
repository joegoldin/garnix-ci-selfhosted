module Garnix.Build.Helpers
  ( withPrivateNixXdgCache,
    withInternalCacheToken,
    cacheHostFromUrl,
  )
where

import Data.Text qualified as T
import Garnix.DB qualified as DB
import Garnix.Monad
import Garnix.Monad.ForkT (safeSystemTempDirectory, safeSystemTempFile)
import Garnix.NixConfig qualified as NixConfig
import Garnix.Prelude
import Garnix.Types as Types
import System.IO (hClose, hPutStrLn)

-- We need to make sure each build has its own cache in order
-- to avoid leaking private repositories between organisations.
withPrivateNixXdgCache :: M a -> M a
withPrivateNixXdgCache action = do
  tempDir <- safeSystemTempDirectory "garnix-cache"
  local (#nixXdgCacheDir ?~ tempDir) $ do
    action <?> "running action with private nix xdg cache"

withInternalCacheToken :: GhLogin -> M a -> M a
withInternalCacheToken reqUser cont = do
  token <- DB.getUserInternalToken reqUser
  cacheHost <- cacheHostFromUrl <$> view #cacheUrl
  (path, handle) <- safeSystemTempFile "garnix-netrc"
  liftIO $ do
    hPutStrLn handle
      . unlines
      $ [ "machine " <> cs cacheHost,
          "login " <> cs (getGhLogin reqUser),
          "password " <> cs (getInternalCacheToken token)
        ]
    hClose handle
  local (#userNixConfig %~ ((NixConfig.fromNetRcFile . NetRcFile $ path) <>)) $ do
    withTextSpan ("internal_token", show reqUser) cont

-- | Bare host for a netrc @machine@ entry: scheme and any path stripped.
-- A netrc @machine@ token is a hostname, so a cache URL with a trailing
-- slash or path (e.g. @https://cache.example.com/foo@) must not leak those
-- segments into the entry.
cacheHostFromUrl :: Text -> Text
cacheHostFromUrl = T.takeWhile (/= '/') . T.replace "https://" "" . T.replace "http://" ""
