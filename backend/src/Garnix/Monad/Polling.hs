module Garnix.Monad.Polling where

import Garnix.Duration
import Garnix.Monad (M, throw)
import Garnix.Prelude
import Garnix.Types (Error (OtherError))

data PollingConfig = PollingConfig
  { interval :: Duration,
    cutOff :: Duration
  }

withPolling :: PollingConfig -> M (Maybe a) -> M a
withPolling cfg action = do
  startPoll <- liftIO getCurrentTime
  inner startPoll
  where
    inner startPoll = do
      result <- action
      case result of
        Nothing -> do
          now <- liftIO getCurrentTime
          when (diffTime now startPoll > cutOff cfg) $ do
            throw $ OtherError "withPolling: Timed out waiting for action to complete"
          threadDelay $ interval cfg
          inner startPoll
        Just value -> pure value
