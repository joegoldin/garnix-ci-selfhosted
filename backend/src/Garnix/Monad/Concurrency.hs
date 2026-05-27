module Garnix.Monad.Concurrency where

import Garnix.Monad
import Garnix.Monad.ForkT (safeFork)
import Garnix.Prelude

forkM :: M () -> M ()
forkM action = do
  _ <- safeFork $ do
    result <- tryEither action
    case result of
      Left (Left exception) -> do
        logSomeException exception
      Left (Right error) -> do
        logError error
      Right () -> pure ()
  pure ()
