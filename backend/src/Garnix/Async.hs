module Garnix.Async where

import Control.Concurrent hiding (threadDelay)
import Control.Concurrent.Async.Lifted (race)
import Control.Exception
import Garnix.Duration
import Garnix.Prelude
import Garnix.Types

-- | Replacement for `Async`. The main differences are:
--
-- 1. `Promise`s also deal with monadic errors, not just runtime exceptions.
--
-- 2. The default behavior when running multiple `Promise`s concurrently is
-- that an error or exception in one of the threads does *not* cancel the
-- others. (See for example `Garnix.Monad.Async.doAllConcurrently`.)
newtype Promise a = Promise {getPromise :: MVar (PromiseResult a)}

data PromiseResult a
  = PromiseException SomeException
  | PromiseThrew ErrorWithContext
  | PromiseSucceeded a
  deriving stock (Functor, Generic, Show)

instance Applicative PromiseResult where
  pure = PromiseSucceeded

  liftA2 :: (a -> b -> c) -> PromiseResult a -> PromiseResult b -> PromiseResult c
  liftA2 f ra rb = case ra of
    PromiseSucceeded a -> case rb of
      PromiseSucceeded b -> PromiseSucceeded $ f a b
      PromiseException e -> PromiseException e
      PromiseThrew e -> PromiseThrew e
    PromiseException e -> PromiseException e
    PromiseThrew e -> PromiseThrew e

instance Monad PromiseResult where
  (>>=) :: PromiseResult a -> (a -> PromiseResult b) -> PromiseResult b
  ra >>= f = case ra of
    PromiseSucceeded a -> f a
    PromiseException e -> PromiseException e
    PromiseThrew e -> PromiseThrew e

resolveIO :: Promise a -> IO (PromiseResult a)
resolveIO (Promise mvar) = readMVar mvar

timeout :: (MonadBaseControl IO m, MonadIO m) => Duration -> m a -> m (Maybe a)
timeout delay action =
  race (liftIO $ threadDelay delay) action >>= \case
    Left _ -> pure Nothing
    Right v -> pure $ Just v

isResolved :: Promise a -> IO Bool
isResolved (Promise mvar) = isJust <$> tryTakeMVar mvar
