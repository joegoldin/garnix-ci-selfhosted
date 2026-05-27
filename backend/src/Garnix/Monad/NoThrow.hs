module Garnix.Monad.NoThrow where

import Control.Concurrent.Async.Lifted qualified
import Control.Exception.Safe qualified as SafeException
import Garnix.Duration
import Garnix.Monad
import Garnix.Prelude

forkForever :: Duration -> M () -> M ThreadId
forkForever delay action =
  fork . forever $ do
    action
      `catchError` logError
      `SafeException.catchAny` logSomeException
    threadDelay delay

replicateConcurrently_ :: Int -> M a -> M ()
replicateConcurrently_ n action = do
  Control.Concurrent.Async.Lifted.replicateConcurrently_ n $ do
    void action
      `catchError` logError
      `SafeException.catchAny` logSomeException

forConcurrently_ :: (Foldable f) => f a -> (a -> M b) -> M ()
forConcurrently_ as action = do
  Control.Concurrent.Async.Lifted.forConcurrently_ as $ \a -> do
    void (action a)
      `catchError` logError
      `SafeException.catchAny` logSomeException
