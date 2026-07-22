module Garnix.Hosting.LogStream.Types where

import Control.Concurrent (MVar, ThreadId)
import Data.Map.Strict (Map)
import Data.Sequence (Seq)
import Data.Text (Text)
import Prelude (Bool, Int, Maybe)

newtype ServerLogStreams = ServerLogStreams
  { unServerLogStreams :: MVar ServerLogStreamsState
  }

data ServerLogStreamsState = ServerLogStreamsState
  { streamsNextGeneration :: Int,
    streamsEntries :: Map Text ServerLogEntry
  }

data ServerLogEntry = ServerLogEntry
  { entryGeneration :: Int,
    entryCollectorThread :: Maybe ThreadId,
    entryConnected :: Bool,
    entryBufferedLines :: Seq Text,
    entryBufferedBytes :: Int,
    entryError :: Maybe Text
  }
