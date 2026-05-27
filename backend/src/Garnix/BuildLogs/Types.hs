module Garnix.BuildLogs.Types (LogLine (..), mkLogLine) where

import Garnix.Prelude
import Garnix.Types

data LogLine = LogLine
  { package :: Maybe PackageName,
    phase :: Maybe Text,
    log :: Text
  }
  deriving stock (Eq, Show, Generic)

mkLogLine :: Text -> LogLine
mkLogLine = LogLine Nothing Nothing
