module Garnix.Watchdog.Utils where

import Control.Concurrent (threadDelay)
import Control.Exception (ErrorCall (ErrorCall))
import Control.Exception.Safe (throwIO)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Data.Text as T
import Data.Text.IO as T
import Data.Time.Clock (UTCTime, diffUTCTime)
import System.IO (stderr)
import Prelude

abort :: String -> IO a
abort = throwIO . ErrorCall

newtype CheckName = CheckName {getCheckName :: Text}
  deriving newtype (Eq, Ord)

log :: (MonadIO m) => CheckName -> Text -> m ()
log (CheckName check) message = liftIO $ T.hPutStrLn stderr $ check <> ": " <> message

newtype Duration = Duration {seconds :: Double}
  deriving stock (Show)
  deriving newtype (Eq, Ord)

fromHour :: Double -> Duration
fromHour = fromMinutes . (* 60)

fromMinutes :: Double -> Duration
fromMinutes = Duration . (* 60)

fromSeconds :: Double -> Duration
fromSeconds = Duration

diff :: UTCTime -> UTCTime -> Duration
diff a b = Duration $ abs $ realToFrac $ diffUTCTime a b

sleep :: (MonadIO m) => Duration -> m ()
sleep (Duration seconds) = liftIO $ threadDelay $ round $ seconds * 1000000
