module Garnix.API.Cache.Types where

import Data.String.Conversions (LBS)
import Data.Text qualified as T
import Garnix.Nix.Types (StoreHash (..))
import Garnix.Nix.Types qualified as Nix
import Garnix.Prelude
import Network.HTTP.Media.MediaType ((//))
import Servant

newtype NarInfoFileName = NarInfoFileName StoreHash
  deriving (Show)

instance FromHttpApiData NarInfoFileName where
  parseUrlPiece path =
    case T.stripSuffix ".narinfo" path of
      Just hash
        | T.length hash == 32 ->
            Right $ NarInfoFileName $ StoreHash hash
      _ -> Left "Expected a .narInfo file"

data NarInfo = NarInfo
  { storePath :: Nix.StorePath,
    narHash :: Text,
    url :: Text,
    narSize :: Int64,
    sig :: Text,
    references :: Text,
    compression :: Compression,
    fileSize :: Int64,
    fileHash :: Text
  }
  deriving (Generic, Show)

instance Accept NarInfo where
  contentType Proxy = "text" // "x-nix-narinfo"

instance MimeRender NarInfo NarInfo where
  mimeRender :: Proxy NarInfo -> NarInfo -> LBS
  mimeRender
    Proxy
    ( NarInfo
        { storePath,
          narHash,
          url,
          narSize,
          sig,
          references,
          compression,
          fileSize,
          fileHash
        }
      ) =
      cs
        $ T.unlines
        $ fmap
          (\(label, value) -> label <> ": " <> value)
          [ ("StorePath", cs storePath),
            ("NarHash", "sha256:" <> narHash),
            ("URL", url),
            ("NarSize", show narSize),
            ( "Compression",
              case compression of
                XZ -> "xz"
            ),
            ("Sig", sig),
            ("References", references),
            ("FileSize", show fileSize),
            ("FileHash", "sha256:" <> fileHash)
          ]

data Compression = XZ
  deriving (Show)
