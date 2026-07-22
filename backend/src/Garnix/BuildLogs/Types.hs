module Garnix.BuildLogs.Types
  ( LogLine (..),
    mkLogLine,
    BuildWaitTracker (..),
    BuildWaitState (..),
    BuildWaitActivity (..),
  )
where

import Control.Concurrent (MVar)
import Data.Map (Map)
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

-- | Process-local live Nix activity. Durable build/run state remains in
-- Postgres; this bounded overlay supplies the useful nested detail while the
-- backend process is attached to Nix.
newtype BuildWaitTracker = BuildWaitTracker (MVar (Map Text BuildWaitState))

data BuildWaitState = BuildWaitState
  { buildWaitStage :: Text,
    buildWaitStageStartedAt :: UTCTime,
    buildWaitLastActivityAt :: UTCTime,
    buildWaitActivities :: Map Int64 BuildWaitActivity
  }

data BuildWaitActivity = BuildWaitActivity
  { buildWaitActivityParent :: Maybe Int64,
    buildWaitActivityKind :: Text,
    buildWaitActivityLabel :: Text,
    buildWaitActivityDetail :: Maybe Text,
    buildWaitActivityHref :: Maybe Text,
    buildWaitActivityStartedAt :: UTCTime,
    buildWaitActivityLastActivityAt :: UTCTime,
    buildWaitActivityBuilder :: Maybe Text,
    buildWaitActivityPhase :: Maybe Text
  }
