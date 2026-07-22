module Garnix.Monad.ConcurrencySpec where

import Control.Concurrent.Lifted (modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar)
import Control.Exception (ErrorCall (..))
import Control.Exception.Lifted (throwIO)
import Garnix.Duration
import Garnix.Monad
import Garnix.Monad.Concurrency
import Garnix.Prelude
import Garnix.TestHelpers
import Garnix.TestHelpers.Monad
import Garnix.Types
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = do
  inM $ aroundM_ suppressLogsWhenPassing $ do
    describe "forkM" $ do
      it "forks the given action" $ do
        mvar <- newEmptyMVar
        forkM $ putMVar mvar ("foo" :: Text)
        readMVar mvar `shouldReturnM` "foo"

      it "runs the action concurrently" $ do
        mvar <- newEmptyMVar
        forkM $ takeMVar mvar
        putMVar mvar ()

      it "logs monadic errors" $ do
        logItem <- waitForOneLogItem $ do
          forkM $ do
            throw (OtherError "test error")
        logItem ^. #severity `shouldBeM` Error
        cs (msg logItem) `shouldContainM` "OtherError: test error"

      it "logs runtime exceptions" $ do
        logItem <- waitForOneLogItem $ do
          forkM $ do
            throwIO (ErrorCall "test error")
        logItem ^. #severity `shouldBeM` Error
        msg logItem `shouldBeM` "runtime exception: test error"

  describe "forkDetachedM" $ do
    it "does not keep runM waiting for detached work" $ do
      started <- newEmptyMVar
      release <- newEmptyMVar
      finished <- newEmptyMVar

      result <- timeout 5000000 $ runTestM $ do
        forkDetachedM $ do
          putMVar started ()
          takeMVar release
          putMVar finished ()

      result `shouldBe` Just ()
      timeout 5000000 (readMVar started) >>= (`shouldBe` Just ())
      putMVar release ()
      timeout 5000000 (readMVar finished) >>= (`shouldBe` Just ())

waitForOneLogItem :: M () -> M LogItem
waitForOneLogItem action = do
  logs <- liftIO $ newMVar []
  let captureLogItem logItem = modifyMVar_ logs $ \acc -> pure (logItem : acc)
  local
    (#logger %~ (\existingLogger logItem -> existingLogger logItem >> captureLogItem logItem))
    action
  waitFor (fromSeconds @Int 5) $ do
    logItems <- readMVar logs
    pure $! fromSingleton logItems
