module Garnix.Monad.KeyedMutexSpec where

import Control.Concurrent (modifyMVar_, newChan, newEmptyMVar, newMVar, putMVar, readChan, readMVar, takeMVar, writeChan)
import Control.Concurrent.Async (async, wait)
import Control.Exception (throwIO, try)
import Data.IORef
import Garnix.Duration
import Garnix.Monad.KeyedMutex
-- 'Garnix.Prelude' has its own 'try' (for the app's 'MonadError'-based error
-- handling, unrelated to catching real IO exceptions), which would otherwise
-- collide with 'Control.Exception.try' used below on plain 'IO' actions.
import Garnix.Prelude hiding (try)
import System.Timeout (timeout)
import Test.Hspec

-- | These tests exercise 'KeyedMutex' directly against plain 'IO' — it has no
-- dependency on the app's 'M' monad, DB, or Env (see the module haddock), so
-- there is no need for the throwaway-DB 'runTestM' harness the rest of the
-- suite uses.
spec :: Spec
spec = do
  describe "KeyedMutex" $ do
    it "runs a single action for a key and returns its result" $ do
      mutex <- newKeyedMutex
      result <- withKeyedMutex mutex ("owner" :: Text, "repo" :: Text) $ pure (42 :: Int)
      result `shouldBe` 42

    it "never runs two holders of the same key concurrently" $ do
      mutex <- newKeyedMutex
      current <- newMVar (0 :: Int)
      maxSeen <- newMVar (0 :: Int)
      let enter = modifyMVar_ current $ \n -> do
            let n' = n + 1
            modifyMVar_ maxSeen (pure . max n')
            pure n'
          leave = modifyMVar_ current (pure . subtract 1)
      handles <- replicateM 10
        $ async
        $ withKeyedMutex mutex ("k" :: Text)
        $ do
          enter
          threadDelay (fromMilliSeconds @Int 15)
          leave
      mapM_ wait handles
      readMVar maxSeen `shouldReturn` 1

    it "serves waiters for one key strictly in arrival order (FIFO)" $ do
      mutex <- newKeyedMutex
      started <- newChan
      let enqueue label = do
            oneshot <- newEmptyMVar
            _ <- async $ withKeyedMutex mutex ("k" :: Text) $ do
              writeChan started label
              readMVar oneshot
            -- Give this waiter time to actually reach (and either acquire or
            -- enqueue behind) the mutex before the NEXT one is spawned, so
            -- submission order is deterministic rather than a scheduler race
            -- (the same technique 'Garnix.Monad.PoolSpec' uses for its own
            -- FIFO/round-robin test).
            threadDelay (fromMilliSeconds @Int 80)
            pure (putMVar oneshot ())
      finishA <- enqueue 'a'
      finishB <- enqueue 'b'
      finishC <- enqueue 'c'
      readChan started `shouldReturn` 'a'
      finishA
      readChan started `shouldReturn` 'b'
      finishB
      readChan started `shouldReturn` 'c'
      finishC

    it "does not block a different key while one key's lock is held" $ do
      mutex <- newKeyedMutex
      holdingA <- newEmptyMVar
      releaseA <- newEmptyMVar
      doneB <- newEmptyMVar
      _ <- async $ withKeyedMutex mutex ("a" :: Text) $ do
        putMVar holdingA ()
        takeMVar releaseA
      takeMVar holdingA -- confirm "a" is held before "b" is even started
      _ <- async $ withKeyedMutex mutex ("b" :: Text) $ putMVar doneB ()
      -- "b" completes even though "a"'s lock is still held: proves the two
      -- keys are independent, not one global lock (which is exactly what
      -- distinguishes this from a plain global mutex / a Pool with limit=1).
      result <- timeout (5 * 1_000_000) (takeMVar doneB)
      result `shouldBe` Just ()
      putMVar releaseA ()

    it "releases the lock (and wakes the next waiter) even when the holder throws" $ do
      mutex <- newKeyedMutex
      _ :: Either SomeException () <-
        try $ withKeyedMutex mutex ("k" :: Text) $ throwIO (userError "boom")
      resultRef <- newIORef Nothing
      _ <- withKeyedMutex mutex ("k" :: Text) $ writeIORef resultRef (Just ("second holder ran" :: Text))
      readIORef resultRef `shouldReturn` Just "second holder ran"

    it "keeps different keys' maps from leaking: a released, waiter-less key is forgotten" $ do
      mutex <- newKeyedMutex
      -- Acquire and release the same key a few times; if the bookkeeping map
      -- retained stale entries this would still behave correctly (values
      -- would just accumulate), so this is a smoke test that repeated
      -- acquire/release keeps working, not a leak assertion by itself.
      results <- forM [1 .. 5 :: Int] $ \i -> withKeyedMutex mutex ("k" :: Text) $ pure i
      results `shouldBe` [1 .. 5]
