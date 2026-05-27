module Garnix.Request
  ( retryingFor,
    retryingWithPolicy,
    retrySequence,
  )
where

import Control.Retry
import Data.Maybe (listToMaybe)
import Garnix.Duration
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types

-- | Retrying with reasonable defaults. Exponential backoff, with a
-- *cumulative* cap of the given seconds.
retryingFor :: Duration -> M a -> M a
retryingFor secs action =
  retryingWithPolicy policy action
  where
    policy :: RetryPolicy
    policy =
      limitRetriesByCumulativeDelay (toMicroseconds secs)
        $ exponentialBackoff 100

retryingWithPolicy :: RetryPolicyM M -> M a -> M a
retryingWithPolicy policy action =
  retryOnError
    policy
    (\_ _ -> pure True)
    (\_ -> action `catchAny` (throw . OtherError . show))

-- | Try all actions in sequence.
retrySequence :: forall a. [M a] -> M a
retrySequence actions = do
  retryOnError policy (\_ _ -> pure True) go
  where
    policy :: RetryPolicy
    policy = limitRetries $ length actions - 1

    go :: RetryStatus -> M a
    go RetryStatus {..} =
      fromMaybe
        (throw $ OtherError "retries policy failed")
        . listToMaybe
        $ drop rsIterNumber actions
