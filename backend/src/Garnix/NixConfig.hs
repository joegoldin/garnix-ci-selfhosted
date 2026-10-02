module Garnix.NixConfig
  ( defaultNixConfig,
    fromNetRcFile,
    getNetRcFileSetting,
    addNixConfigEnvironment,
    formatConfig,
    nixConfDefaults,
  )
where

import Cradle
import Data.Map.Strict qualified as Map
import Garnix.Prelude
import Garnix.Types (NetRcFile (..), NixConfig (..))

-- Extends the host's experimental features rather than replacing them, so a
-- feature the operator enables in nix.conf (dynamic-derivations, say) still
-- applies when garnix evaluates and builds.
defaultNixConfig :: NixConfig
defaultNixConfig =
  NixConfig $ Map.insert "extra-experimental-features" (unwords ["nix-command", "flakes", "pipe-operators"]) mempty

fromNetRcFile :: NetRcFile -> NixConfig
fromNetRcFile file = NixConfig $ Map.insert "netrc-file" (getNetRcFile file) mempty

getNetRcFileSetting :: NixConfig -> Maybe NetRcFile
getNetRcFileSetting (NixConfig m) = NetRcFile <$> Map.lookup "netrc-file" m

formatConfig :: NixConfig -> String
formatConfig (NixConfig config) =
  intercalate "\n" $ map (\(key, value) -> key <> " = " <> value) $ Map.assocs config

addNixConfigEnvironment :: NixConfig -> ProcessConfiguration -> ProcessConfiguration
addNixConfigEnvironment config =
  modifyEnvVar
    "NIX_CONFIG"
    $ \case
      Nothing -> Just $ formatConfig config
      Just existing -> Just $ existing <> "\n" <> formatConfig config

nixConfDefaults :: ProcessConfiguration -> ProcessConfiguration
nixConfDefaults = addArgs ["--extra-experimental-features", "nix-command flakes" :: Text]
