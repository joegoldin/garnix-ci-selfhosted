module Garnix.ExpiringCache
  ( ExpiringCache,
    mkCache,
    lookupCache,
    clearCache,
  )
where

import Control.Concurrent.Lifted
import Data.Bitraversable (bitraverse)
import Data.Map.Strict (Map, insert, lookup)
import Garnix.Duration
import Garnix.Monad
import Garnix.Prelude hiding (insert, lookup)
import Garnix.Types

data CacheValue a = CacheValue
  { value :: Either ErrorWithContext a,
    expiresAt :: UTCTime
  }

data ExpiringCache k v = ExpiringCache
  { name :: Maybe Text,
    cacheMVar :: MVar (Map k (MVar (Maybe (CacheValue v)))),
    ttl :: Duration,
    errorTtl :: Duration
  }

mkCache :: (Ord k) => Maybe Text -> Duration -> Duration -> IO (ExpiringCache k v)
mkCache name ttl errorTtl = do
  cacheMVar <- newMVar mempty
  pure $ ExpiringCache {name, cacheMVar, ttl, errorTtl}

clearCache :: (MonadIO m, Ord key) => ExpiringCache key val -> m ()
clearCache ExpiringCache {cacheMVar} = void $ liftIO $ swapMVar cacheMVar mempty

lookupCache :: (Show key, Ord key) => ExpiringCache key val -> key -> M val -> M val
lookupCache ExpiringCache {name, cacheMVar, ttl, errorTtl} key notInCacheAction = do
  inner <- modifyMVar cacheMVar $ \map -> case lookup key map of
    Just innerMVar -> pure (map, innerMVar)
    Nothing -> do
      innerMVar <- newMVar Nothing
      pure (insert key innerMVar map, innerMVar)
  result <- modifyMVar inner $ \mVal -> do
    now <- liftIO getCurrentTime
    let getNewCacheValue = do
          newVal <- try notInCacheAction
          let expiresAt = addTime (either (const errorTtl) (const ttl) newVal) now
          pure (Just $ CacheValue newVal expiresAt, newVal)
        logCacheEvent event = case name of
          Just name -> log Informational $ name <> ": " <> event <> " for " <> show key
          Nothing -> pure ()
    case mVal of
      Nothing -> do
        logCacheEvent "cache miss"
        getNewCacheValue
      Just (CacheValue {value, expiresAt}) ->
        if expiresAt <= now
          then do
            logCacheEvent "cache expired"
            getNewCacheValue
          else do
            logCacheEvent "cache hit"
            (mVal,) <$> bitraverse wrapAsCachedError pure value
  either rethrow pure result
  where
    wrapAsCachedError :: ErrorWithContext -> M ErrorWithContext
    wrapAsCachedError error = do
      spans <- asks spanCtx
      pure
        $ ErrorWithContext
          { callstack = callStack,
            spans,
            severity = error ^. #severity,
            err = CachedError error
          }
