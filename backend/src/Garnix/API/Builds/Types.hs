module Garnix.API.Builds.Types where

import Garnix.Prelude
import Garnix.Types

data BuildLogs = BuildLogs
  { _buildLogsFinished :: Bool,
    _buildLogsMaxPageSize :: Int,
    _buildLogsLogs :: [OpenSearchMessage]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON BuildLogs where
  toEncoding = ourToEncoding
  toJSON = ourToJSON
