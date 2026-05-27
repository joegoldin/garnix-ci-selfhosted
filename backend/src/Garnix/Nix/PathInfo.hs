module Garnix.Nix.PathInfo where

import Control.Lens
import Cradle
import Data.Aeson ((.:))
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Garnix.Monad
import Garnix.Monad.SubProcess (runSubProcess)
import Garnix.Nix.Types
import Garnix.Nix.Types qualified as Nix
import Garnix.NixConfig (addNixConfigEnvironment)
import Garnix.Prelude
import Garnix.Types

-- | Doesn't contain *all* the fields from `nix path-info`, but the ones we needed so far.
data PathInfo = PathInfo
  { signatures :: [Text],
    references :: [StorePath]
  }
  deriving stock (Generic)

instance FromJSON PathInfo where
  parseJSON = Aeson.withObject "nix path-info output" $ \o -> do
    signatures <- o .: "signatures"
    references <- o .: "references"
    parsedReferences <- forM references $ \reference -> do
      case Nix.parseStorePath (reference :: Text) of
        Right ref -> pure ref
        Left error -> fail $ cs error
    pure
      $ PathInfo
        { signatures,
          references = parsedReferences
        }

getPathInfo :: StorePath -> M PathInfo
getPathInfo storePath = do
  nixConfig <- view #userNixConfig
  StdoutRaw output <-
    runSubProcess $ cmd "nix"
      & addArgs
        ["path-info", "--json", cs storePath :: Text]
      & addNixConfigEnvironment nixConfig
  parsed :: Map.Map Text PathInfo <- aesonDecode "nix path-info output" parseJSON (cs output)
  case Map.lookup (cs storePath) parsed of
    Just pathInfo -> pure pathInfo
    Nothing -> throw $ OtherError "Error parsing `nix path-info` output: cannot find store path"

signaturesForCacheKey :: PathInfo -> Text -> [Text]
signaturesForCacheKey pathInfo cacheKeyName = do
  filter ((cacheKeyName <> ":") `T.isPrefixOf`) (pathInfo ^. #signatures)
