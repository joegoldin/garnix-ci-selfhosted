module Garnix.BuildLogs.Internal where

import Data.Aeson
import Garnix.Prelude

newtype InternalId = InternalId {getInternalId :: Int64}
  deriving stock (Eq, Show, Generic, Ord)

instance FromJSON InternalId where
  parseJSON value = InternalId <$> parseJSON value

-- https://github.com/NixOS/nix/blob/bd7a0746361d42a121b2cef1571bda4f7c370c16/src/libutil/error.hh#L37-L46
data LogLevel
  = LvlError
  | LvlWarn
  | LvlNotice
  | LvlInfo
  | LvlTalkative
  | LvlChatty
  | LvlDebug
  | LvlVomit
  deriving stock (Eq, Show, Generic)

instance FromJSON LogLevel where
  parseJSON = withScientific "LogLevel" $ \v -> do
    case v of
      0 -> pure LvlError
      1 -> pure LvlWarn
      2 -> pure LvlNotice
      3 -> pure LvlInfo
      4 -> pure LvlTalkative
      5 -> pure LvlChatty
      6 -> pure LvlDebug
      7 -> pure LvlVomit
      _ -> fail $ "Unknown log level: " <> cs (show v)

data ProgressReport = ProgressReport
  { done :: Int64,
    expected :: Int64,
    running :: Int64,
    failed :: Int64
  }
  deriving stock (Eq, Show, Generic)

data InternalBuildLogLineStart
  = Build Text Text Text
  | Builds Text
  | CopyPaths Text
  | Unknown Text
  | QueryPathInfo Text
  | FileTransfer Text
  | Realize Text
  | OtherStartType -- Catchall for types we don't care about
  deriving stock (Eq, Show, Generic)

data InternalBuildLogLineResult
  = SetPhase Text
  | SetExpected Int Int
  | LogLine Text
  | Progress ProgressReport
  | OtherResultType -- Catchall for types we don't care about
  deriving stock (Eq, Show, Generic)

data InternalBuildLogLine
  = Start InternalId (Maybe InternalId) LogLevel InternalBuildLogLineStart
  | Stop InternalId
  | Result InternalId InternalBuildLogLineResult
  | Unhandled
  | Msg Text
  deriving stock (Eq, Show, Generic)

instance FromJSON InternalBuildLogLine where
  parseJSON = withObject "InternalBuildLogLine" $ \v -> do
    action :: Text <- v .: "action"
    case action of
      "start" -> do
        typ :: Int <- v .: "type"
        id :: InternalId <- v .: "id"
        parent :: Maybe InternalId <- v .:? "parent"
        level :: LogLevel <- v .: "level"
        -- `typ` is `ActivityType` declared here:
        -- https://github.com/NixOS/nix/blob/bd7a0746361d42a121b2cef1571bda4f7c370c16/src/libutil/logging.hh#L12-L27
        Start id parent level <$> case typ of
          0 -> Unknown <$> v .: "text"
          101 -> FileTransfer <$> v .: "text"
          102 -> Realize <$> v .: "text"
          103 -> CopyPaths <$> v .: "text"
          104 -> Builds <$> v .: "text"
          105 -> do
            text <- v .: "text"
            (drvPath, machine, _, _) :: (Text, Text, Int, Int) <- v .: "fields"
            pure $ Build drvPath machine text
          109 -> QueryPathInfo <$> v .: "text"
          _ -> pure OtherStartType
      "stop" -> Stop <$> v .: "id"
      "result" -> do
        -- `typ` is `ResultType` declared here:
        -- https://github.com/NixOS/nix/blob/bd7a0746361d42a121b2cef1571bda4f7c370c16/src/libutil/logging.hh#L29-L39
        typ :: Int <- v .: "type"
        id :: InternalId <- v .: "id"
        Result id <$> case typ of
          101 -> LogLine <$> (fromSingleton =<< v .: "fields")
          104 -> SetPhase <$> (fromSingleton =<< v .: "fields")
          105 -> do
            (done, expected, running, failed) <- v .: "fields"
            pure $ Progress $ ProgressReport done expected running failed
          106 -> do
            (actType, expected) <- v .: "fields"
            pure $ SetExpected actType expected
          _ -> pure OtherResultType
      "msg" -> do
        msg :: Text <- v .: "msg"
        pure $ Msg msg
      a -> fail $ "Unknown action: " <> cs a
    where
      fromSingleton arr = do
        case arr of
          [value] -> pure value
          _ -> fail "fromSingleton: Expected a single element"
