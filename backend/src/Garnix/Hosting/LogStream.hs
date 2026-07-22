module Garnix.Hosting.LogStream
  ( ServerLogSnapshot (..),
    newServerLogStreams,
    startServerLogStream,
    stopServerLogStream,
    forgetServerLogStream,
    resumeServerLogStreams,
    getServerLogSnapshot,
    appendServerLogLine,
  )
where

import Control.Concurrent (forkIO, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar, threadDelay)
import Control.Concurrent qualified as Concurrent
import Control.Concurrent.Async qualified as Async
import Control.Exception.Safe qualified as Safe
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Garnix.DB qualified as DB
import Garnix.Hosting.LogStream.Types
import Garnix.Hosting.ServerPool qualified as ServerPool
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import System.Exit (ExitCode)
import System.IO (hIsEOF)
import System.Process qualified as Proc

-- | The API deliberately exposes only buffered text and coarse collector
-- state. The SSH command, guest address and configured path never cross the
-- browser boundary.
data ServerLogSnapshot = ServerLogSnapshot
  { _serverLogSnapshotConfigured :: Bool,
    _serverLogSnapshotConnected :: Bool,
    _serverLogSnapshotLines :: [Text],
    _serverLogSnapshotError :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ServerLogSnapshot where
  toJSON = ourToJSON

newServerLogStreams :: IO ServerLogStreams
newServerLogStreams =
  ServerLogStreams <$> newMVar (ServerLogStreamsState 0 Map.empty)

-- | Begin following a configured guest log. Starting again for the same
-- server (a persistent redeploy) replaces the old collector and its buffer,
-- so the modal describes the current server start rather than mixing runs.
startServerLogStream :: ServerId -> Text -> Text -> M ()
startServerLogStream serverId ipv4 path = do
  streams <- view #serverLogStreams
  (_, sshArgs) <- ServerPool.sshArgsForAddress ipv4
  liftIO $ startCollector streams (serverKey serverId) ipv4 sshArgs path

-- | Stop network/process activity but retain the bounded buffer while this
-- backend process lives. This keeps logs convenient for a recently-ended
-- server without turning the database into a second application-log store.
stopServerLogStream :: ServerId -> M ()
stopServerLogStream serverId = do
  streams <- view #serverLogStreams
  liftIO $ stopCollector streams (serverKey serverId) False

-- | Remove both collector and buffer, used when a redeploy removes logFile.
forgetServerLogStream :: ServerId -> M ()
forgetServerLogStream serverId = do
  streams <- view #serverLogStreams
  liftIO $ stopCollector streams (serverKey serverId) True

-- | Process restart recovery. Memory is intentionally ephemeral, so each
-- live configured server starts a fresh collector seeded from the newest
-- 10,000 lines.
resumeServerLogStreams :: M Int
resumeServerLogStreams = do
  configs <- DB.getActiveServerLogFiles
  forM_ configs $ \(serverId, ipv4, path) -> startServerLogStream serverId ipv4 path
  pure (length configs)

getServerLogSnapshot :: ServerId -> Bool -> M ServerLogSnapshot
getServerLogSnapshot serverId isConfigured = do
  streams <- view #serverLogStreams
  liftIO $ snapshot streams (serverKey serverId) isConfigured

-- | Exported as a narrow regression-test seam for ring-buffer bounds and the
-- auth-gated API. Production writes arrive only from the SSH tail collector.
appendServerLogLine :: ServerId -> Text -> M ()
appendServerLogLine serverId line = do
  streams <- view #serverLogStreams
  liftIO $ appendLine streams (serverKey serverId) Nothing line

startCollector :: ServerLogStreams -> Text -> Text -> [Text] -> Text -> IO ()
startCollector streams key ip sshArgs path = do
  stopCollector streams key True
  gate <- newEmptyMVar
  generation <-
    modifyMVar (unServerLogStreams streams) $ \state -> do
      let generation = streamsNextGeneration state + 1
          entry = ServerLogEntry generation Nothing False Seq.empty 0 Nothing
      pure
        ( state
            { streamsNextGeneration = generation,
              streamsEntries = Map.insert key entry (streamsEntries state)
            },
          generation
        )
  collectorThread <- forkIO $ takeMVar gate >> collectorLoop streams key generation ip sshArgs path
  modifyMVar_ (unServerLogStreams streams) $ \state ->
    pure
      state
        { streamsEntries =
            Map.adjust
              (\entry -> if entryGeneration entry == generation then entry {entryCollectorThread = Just collectorThread} else entry)
              key
              (streamsEntries state)
        }
  putMVar gate ()

stopCollector :: ServerLogStreams -> Text -> Bool -> IO ()
stopCollector streams key forget = do
  oldThread <-
    modifyMVar (unServerLogStreams streams) $ \state ->
      case Map.lookup key (streamsEntries state) of
        Nothing -> pure (state, Nothing)
        Just entry ->
          let entries' =
                if forget
                  then Map.delete key (streamsEntries state)
                  else Map.insert key (entry {entryCollectorThread = Nothing, entryConnected = False}) (streamsEntries state)
           in pure (state {streamsEntries = entries'}, entryCollectorThread entry)
  traverse_ Concurrent.killThread oldThread

collectorLoop :: ServerLogStreams -> Text -> Int -> Text -> [Text] -> Text -> IO ()
collectorLoop streams key generation ip sshArgs path = forever $ do
  followOnce `Safe.catchAny` \err -> setError streams key generation (T.take maxErrorChars (show err))
  setConnected streams key generation False
  threadDelay 3_000_000
  where
    followOnce =
      Proc.withCreateProcess process $ \_ maybeStdout maybeStderr processHandle ->
        case (maybeStdout, maybeStderr) of
          (Just stdoutHandle, Just stderrHandle) -> do
            setConnected streams key generation True
            setError streams key generation ""
            Async.withAsync (consumeStderr stderrHandle) $ \_ -> do
              consumeStdout stdoutHandle
              exitCode <- Proc.waitForProcess processHandle
              setError streams key generation ("log collector exited (" <> showExit exitCode <> ")")
          _ -> Safe.throwString "log collector failed to create stdout and stderr pipes"
    process =
      ( Proc.proc
          "ssh"
          ( map cs sshArgs
              <> [ "garnix@" <> cs ip,
                   cs ("sudo -n tail -n " <> show initialTailLines <> " -F -- " <> shellQuote path)
                 ]
          )
      )
        { Proc.std_in = Proc.NoStream,
          Proc.std_out = Proc.CreatePipe,
          Proc.std_err = Proc.CreatePipe
        }
    consumeStdout handle = readHandleLines handle $ \line -> do
      setError streams key generation ""
      appendLine streams key (Just generation) line
    consumeStderr handle = readHandleLines handle (setError streams key generation)

readHandleLines :: Handle -> (Text -> IO ()) -> IO ()
readHandleLines handle consume = do
  eof <- hIsEOF handle
  unless eof $ do
    line <- TE.decodeUtf8With lenientDecode <$> BS.hGetLine handle
    consume line
    readHandleLines handle consume

appendLine :: ServerLogStreams -> Text -> Maybe Int -> Text -> IO ()
appendLine streams key expectedGeneration rawLine =
  modifyMVar_ (unServerLogStreams streams) $ \state ->
    pure state {streamsEntries = Map.alter update key (streamsEntries state)}
  where
    line = T.take maxLineChars rawLine
    update Nothing =
      case expectedGeneration of
        Just _ -> Nothing
        Nothing -> Just (boundedEntry (ServerLogEntry 0 Nothing False Seq.empty 0 Nothing) line)
    update (Just entry)
      | maybe True (== entryGeneration entry) expectedGeneration = Just (boundedEntry entry line)
      | otherwise = Just entry

boundedEntry :: ServerLogEntry -> Text -> ServerLogEntry
boundedEntry entry line =
  trim
    $ entry
      { entryBufferedLines = entryBufferedLines entry Seq.|> line,
        entryBufferedBytes = entryBufferedBytes entry + textBytes line
      }
  where
    trim current
      | Seq.length (entryBufferedLines current) <= maxBufferedLines && entryBufferedBytes current <= maxBufferedBytes = current
      | otherwise =
          case Seq.viewl (entryBufferedLines current) of
            Seq.EmptyL -> current {entryBufferedBytes = 0}
            oldest Seq.:< rest ->
              trim
                $ current
                  { entryBufferedLines = rest,
                    entryBufferedBytes = entryBufferedBytes current - textBytes oldest
                  }

    textBytes = BS.length . TE.encodeUtf8

snapshot :: ServerLogStreams -> Text -> Bool -> IO ServerLogSnapshot
snapshot streams key isConfigured = do
  state <- readMVar (unServerLogStreams streams)
  pure $ case Map.lookup key (streamsEntries state) of
    Just entry ->
      ServerLogSnapshot
        isConfigured
        (entryConnected entry)
        (toList (entryBufferedLines entry))
        (entryError entry)
    Nothing -> ServerLogSnapshot isConfigured False [] Nothing

setConnected :: ServerLogStreams -> Text -> Int -> Bool -> IO ()
setConnected streams key expected value =
  adjustCurrent streams key expected $ \entry -> entry {entryConnected = value}

setError :: ServerLogStreams -> Text -> Int -> Text -> IO ()
setError streams key expected value =
  adjustCurrent streams key expected $ \entry ->
    entry {entryError = if T.null value then Nothing else Just (T.take maxErrorChars value)}

adjustCurrent :: ServerLogStreams -> Text -> Int -> (ServerLogEntry -> ServerLogEntry) -> IO ()
adjustCurrent streams key expected update =
  modifyMVar_ (unServerLogStreams streams) $ \state ->
    pure
      state
        { streamsEntries =
            Map.adjust
              (\entry -> if entryGeneration entry == expected then update entry else entry)
              key
              (streamsEntries state)
        }

serverKey :: ServerId -> Text
serverKey = getHashId . getServerId

-- SSH joins the remote command through a shell. Single-quote the validated
-- absolute path anyway, so spaces and quotes remain data rather than syntax.
shellQuote :: Text -> Text
shellQuote value = "'" <> T.replace "'" "'\\''" value <> "'"

showExit :: ExitCode -> Text
showExit = show

initialTailLines, maxBufferedLines, maxBufferedBytes, maxLineChars, maxErrorChars :: Int
initialTailLines = 10_000
maxBufferedLines = 10_000
maxBufferedBytes = 10 * 1024 * 1024
maxLineChars = 16 * 1024
maxErrorChars = 2048
