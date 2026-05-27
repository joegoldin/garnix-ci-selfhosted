module Garnix.Monad.NoThrowSpec where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar
import Control.Exception.Lifted (ErrorCall (ErrorCall), throwIO)
import Garnix.Duration
import Garnix.Monad
import Garnix.Monad.NoThrow
import Garnix.Prelude
import Garnix.TestHelpers hiding (shouldReturn)
import Garnix.TestHelpers.Monad hiding (captureLogs_)
import Garnix.TestHelpers.Monad qualified as M
import Garnix.Types
import Test.Hspec

spec :: Spec
spec = inM $ aroundM_ suppressLogsWhenPassing $ do
  describe "forkForever" $ do
    let duration = fromMilliSeconds @Int 10
    it "runs the concurrently" $ do
      proof <- liftIO $ newTVarIO False
      void $ forkForever duration (liftIO . atomically $ writeTVar proof True)
      waitFor (fromSeconds @Int 1) $ do
        liftIO (readTVarIO proof) `shouldReturnM` True

    it "repeats the action" $ do
      proof <- liftIO $ newTVarIO (0 :: Int)
      void $ forkForever duration (liftIO . atomically $ modifyTVar proof succ)
      waitFor (fromSeconds @Int 1) $ do
        result <- liftIO (readTVarIO proof)
        result `shouldSatisfyM` (> 10)

    it "retries for M errors" $ do
      proof <- liftIO $ newTVarIO (0 :: Int)
      let action = do
            result <- liftIO . atomically $ stateTVar proof (\prev -> (prev, succ prev))
            when (result == 0) $ throw $ OtherError "fail first"
      [LogItem Error [] message] <- M.captureLogs_ $ do
        void $ forkForever duration action
        waitFor (fromSeconds @Int 1) $ do
          result <- liftIO (readTVarIO proof)
          result `shouldSatisfyM` (> 10)
      liftIO $ cs message `shouldStartWith` "OtherError: fail first"

    it "retries for runtime exceptions" $ do
      proof <- liftIO $ newTVarIO (0 :: Int)
      let action = do
            result <- liftIO . atomically $ stateTVar proof (\prev -> (prev, succ prev))
            when (result == 0) $ throwIO $ ErrorCall "fail first"
      logs <- M.captureLogs_ $ do
        void $ forkForever duration action
        waitFor (fromSeconds @Int 1) $ do
          result <- liftIO (readTVarIO proof)
          result `shouldSatisfyM` (> 10)
      logs `shouldBeM` [LogItem Error [] "runtime exception: fail first"]

  describe "replicateConcurrently_" $ do
    it "spawns multiple threads" $ do
      proof <- liftIO $ newTVarIO (0 :: Int)
      void $ replicateConcurrently_ 5 $ do
        liftIO $ atomically $ modifyTVar proof succ
      waitFor (fromSeconds @Int 1) $ do
        liftIO (readTVarIO proof) `shouldReturnM` 5

    it "waits for all threads to complete" $ do
      proof <- liftIO $ newTVarIO ("initial" :: String)
      void $ replicateConcurrently_ 1 $ do
        threadDelay (fromMilliSeconds @Int 500)
        liftIO $ atomically $ swapTVar proof "done"
      liftIO (readTVarIO proof) `shouldReturnM` "done"

    it "does not interrupt other threads if one throws a runtime exception" $ do
      counter <- liftIO $ newTVarIO (0 :: Int)
      doneCounter <- liftIO $ newTVarIO (0 :: Int)
      logs <- M.captureLogs_ $ do
        void $ replicateConcurrently_ 5 $ do
          result <- liftIO . atomically $ stateTVar counter (\prev -> (prev, succ prev))
          when (result == 0) $ throwIO $ ErrorCall "fail first"
          threadDelay $ fromMilliSeconds @Int 20
          liftIO . atomically $ modifyTVar doneCounter succ
        liftIO (readTVarIO doneCounter) `shouldReturnM` 4
      logs `shouldBeM` [LogItem Error [] "runtime exception: fail first"]

    it "does not interrupt other threads if one throws a monadic error" $ do
      counter <- liftIO $ newTVarIO (0 :: Int)
      doneCounter <- liftIO $ newTVarIO (0 :: Int)
      [LogItem Error [] message] <- M.captureLogs_ $ do
        void $ replicateConcurrently_ 5 $ do
          result <- liftIO . atomically $ stateTVar counter (\prev -> (prev, succ prev))
          when (result == 0) $ throw $ OtherError "fail first"
          threadDelay $ fromMilliSeconds @Int 20
          liftIO . atomically $ modifyTVar doneCounter succ
        liftIO (readTVarIO doneCounter) `shouldReturnM` 4
      liftIO $ cs message `shouldStartWith` "OtherError: fail first"

    it "relays `killThread`" $ do
      counter <- liftIO $ newTVarIO (0 :: Int)
      thread <- fork $ do
        void $ replicateConcurrently_ 5 $ do
          threadDelay $ fromMilliSeconds @Int 100
          liftIO . atomically $ modifyTVar counter succ
      killThread thread
      threadDelay $ fromMilliSeconds @Int 200
      liftIO $ readTVarIO counter `shouldReturn` 0
