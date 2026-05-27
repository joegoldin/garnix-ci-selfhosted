module Garnix.Monad.MemoizationSpec where

import Control.Concurrent.Lifted (MVar, newMVar)
import Data.HashTable.IO qualified as HashTables
import Data.IORef.Lifted (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import Garnix.Duration
import Garnix.Monad.Memoization (MemoTable, memoize)
import Garnix.Prelude
import Test.Hspec

data TestContext = TC {cache :: MVar (MemoTable Text Text)}
  deriving (Generic)

type TestM = ReaderT TestContext IO

runTestM :: TestM a -> IO a
runTestM action = do
  ht <- HashTables.new
  context <- TC <$> newMVar ht
  runReaderT action context

spec :: Spec
spec = do
  describe "memoize" $ do
    it "executes the inner action on the first call" $ do
      runTestM $ do
        ref <- newIORef ("" :: Text)
        let memoized arg = memoize #cache arg $ do
              writeIORef ref "foo"
              pure ""
        void $ memoized ""
        liftIO (readIORef ref `shouldReturn` "foo")

    it "memoizes in a cache in the Reader context" $ do
      runTestM $ do
        ref :: IORef [Text] <- newIORef []
        let memoized arg = memoize #cache arg $ do
              modifyIORef' ref (arg :)
              pure $ T.reverse arg
        a <- memoized "foo"
        liftIO (a `shouldBe` "oof")
        liftIO (readIORef ref `shouldReturn` ["foo"])
        b <- memoized "bar"
        liftIO (b `shouldBe` "rab")
        liftIO (readIORef ref `shouldReturn` ["bar", "foo"])
        cached <- memoized "foo"
        liftIO (cached `shouldBe` "oof")
        liftIO (readIORef ref `shouldReturn` ["bar", "foo"])

    it "doesn't coredump when used concurrently" $ do
      runTestM $ do
        let memoized arg = memoize #cache arg $ do
              threadDelay (fromMilliSeconds @Int 10)
              pure $ T.reverse arg
        forConcurrently_ [1 .. 100 :: Int] $ \i -> do
          memoized (show i)
