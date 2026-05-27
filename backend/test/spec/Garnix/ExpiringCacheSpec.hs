module Garnix.ExpiringCacheSpec (spec) where

import Control.Concurrent hiding (threadDelay)
import Garnix.Duration
import Garnix.ExpiringCache
import Garnix.Monad
import Garnix.Monad.Async
import Garnix.Prelude
import Garnix.TestHelpers (shouldMatchRegexp)
import Garnix.TestHelpers.Monad
import Garnix.TestInstances ()
import Garnix.Types hiding (context)
import Test.Hspec

spec :: Spec
spec = inM $ aroundM_ suppressLogsWhenPassing $ do
  describe "ExpiringCache" $ do
    it "returns passed value if not in the cache" $ do
      cache <- mkTestCache
      lookupCache cache "a" (pure "foo") `shouldReturnM` "foo"

    it "caches values" $ do
      cache <- mkTestCache
      void $ lookupCache cache "a" (pure "foo")
      lookupCache cache "a" (pure "bar") `shouldReturnM` "foo"

    it "partitions by key" $ do
      cache <- mkTestCache
      void $ lookupCache cache "a" (pure "foo")
      lookupCache cache "b" (pure "bar") `shouldReturnM` "bar"

    it "doesn't block other keys" $ do
      let blockIndefinitely = forever $ threadDelay (fromHours @Int 1)
      cache <- mkTestCache
      waitUntilInBlockingFn <- liftIO newEmptyMVar
      void $ spawn $ lookupCache cache "a" $ do
        liftIO $ putMVar waitUntilInBlockingFn ()
        blockIndefinitely
      liftIO $ readMVar waitUntilInBlockingFn
      lookupCache cache "b" (pure "foo") `shouldReturnM` "foo"

    it "limits the amount of requests by key" $ do
      queryMVar <- liftIO $ newMVar []
      let query key = do
            modifyMVar_ queryMVar $ pure . (key :)
            pure "query result"
      cache <- mkTestCache
      promises <- replicateM 500 $ do
        forM ["key1", "key2", "key3"] $ \cacheKey -> do
          spawn $ lookupCache cache cacheKey $ liftIO $ query cacheKey
      resolve =<< joinAll_ =<< forM promises joinAll_
      (sort <$> liftIO (readMVar queryMVar)) `shouldReturnM` ["key1", "key2", "key3"]

    it "expels cache values older than ttl" $ do
      cache <-
        liftIO
          $ mkCache @Text @Text
            Nothing
            (fromMilliSeconds @Int 200)
            (fromMilliSeconds @Int 200)
      void $ lookupCache cache "foo" (pure "bar")
      threadDelay (fromMilliSeconds @Int 200)
      lookupCache cache "foo" (pure "baz") `shouldReturnM` "baz"

    context "monadic errors" $ do
      it "leaves errors unmodified" $ do
        cache <- mkTestCache
        result <- try $ lookupCache cache "a" (throw $ OtherError "error")
        first err result `shouldBeM` Left (OtherError "error")

      it "caches errors" $ do
        cache <- mkTestCache
        void $ try $ lookupCache cache "a" (throw $ OtherError "error")
        Left (ErrorWithContext _ _ _ (CachedError (ErrorWithContext _ _ _ cachedError))) <- try $ lookupCache cache "a" (pure "foo")
        cachedError `shouldBeM` OtherError "error"

      it "shows cached errors clearly as cached" $ do
        cache <- mkTestCache
        void $ try $ lookupCache cache "a" (throw $ OtherError "test error")
        Left cached <- try $ lookupCache cache "a" (pure "foo")
        liftIO $ show (err cached) `shouldMatchRegexp` "CachedError.*"
        show (pretty (err cached)) `shouldBeM` "(cached error) test error"
        userMessage (toErrorDetails cached) `shouldBeM` "(cached error) test error"

      it "expels errors with a different TTL than successful values" $ do
        cache <- liftIO $ mkCache @Text @Text Nothing (fromSeconds @Int 10) (fromMilliSeconds @Int 200)
        void $ try $ lookupCache cache "foo" (throw $ OtherError "error")
        threadDelay (fromMilliSeconds @Int 200)
        result <- try $ lookupCache cache "foo" (pure "foo")
        result `shouldBeM` Right "foo"

mkTestCache :: M (ExpiringCache Text Text)
mkTestCache = liftIO $ mkCache Nothing (fromSeconds @Int 10) (fromSeconds @Int 10)
