module Garnix.Monad.Memoization where

import Control.Concurrent.Lifted (MVar, modifyMVar)
import Control.Lens
import Data.HashTable.IO qualified as HashTables
import Data.HashTable.IO qualified as HashTables.HashTables
import Data.Hashable (Hashable)
import Garnix.Prelude

type MemoTable key result = HashTables.HashTables.LinearHashTable key result

memoize ::
  forall context m input output.
  (MonadReader context m, Hashable input, MonadIO m, MonadBaseControl IO m) =>
  Getting (MVar (MemoTable input output)) context (MVar (MemoTable input output)) ->
  input ->
  m output ->
  m output
memoize cacheLens key action = do
  cached <- withCache $ \cache -> do
    liftIO $ HashTables.lookup cache key
  case cached of
    Just result -> pure result
    Nothing -> do
      result <- action
      withCache $ \cache -> do
        liftIO $ HashTables.insert cache key result
      pure result
  where
    withCache :: (MemoTable input output -> m a) -> m a
    withCache action = do
      cacheMVar <- view cacheLens
      modifyMVar cacheMVar $ \cache -> do
        result <- action cache
        pure (cache, result)
