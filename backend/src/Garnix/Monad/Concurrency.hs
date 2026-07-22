module Garnix.Monad.Concurrency where

import Control.Concurrent (forkIO)
import Garnix.Monad
import Garnix.Monad.ForkT (safeFork)
import Garnix.Prelude

forkM :: M () -> M ()
forkM action = do
  _ <- safeFork $ logForkErrors action
  pure ()

-- | Fork work without keeping the surrounding 'runM' alive. This is reserved
-- for process-lifetime work such as startup recovery: ordinary request work
-- should use 'forkM' so its resources are released only after its children
-- finish.
forkDetachedM :: M () -> M ()
forkDetachedM action = do
  env <- ask
  _ <- liftIO $ forkIO $ void $ runM env $ logForkErrors action
  pure ()

logForkErrors :: M () -> M ()
logForkErrors action = do
  result <- tryEither action
  case result of
    Left (Left exception) -> logSomeException exception
    Left (Right error) -> logError error
    Right () -> pure ()
