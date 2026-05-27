module Garnix.GithubInterfaceSpec where

import Data.IORef.Lifted (modifyIORef, newIORef, readIORef)
import Garnix.GithubInterface (_retryGithubRequest, _retryWhen)
import Garnix.Monad
import Garnix.Prelude
import Garnix.TestHelpers.Monad
import Garnix.Types
import GitHub qualified as GH
import Network.HTTP.Client (HttpException (..), HttpExceptionContent (..), parseRequest)
import Test.Hspec

spec :: Spec
spec = inM $ aroundM_ suppressLogsWhenPassing $ do
  describe "_retryWhen" $ do
    it "runs the given action" $ do
      counter <- newIORef (0 :: Int)
      result <- _retryWhen (pure False) $ do
        modifyIORef counter succ
        pure ("foo" :: Text)
      result `shouldBeM` "foo"
      readIORef counter `shouldReturnM` 1

    it "reruns given actions when the predicate returns True" $ do
      counter <- newIORef (0 :: Int)
      let shouldRetry i = i <= 1
      result <- _retryWhen shouldRetry $ do
        modifyIORef counter succ
        readIORef counter
      result `shouldBeM` 2
      readIORef counter `shouldReturnM` 2

    it "logs why something got retried" $ do
      counter <- newIORef (0 :: Int)
      let shouldRetry (_, i) = i <= 1
      logs <- captureLogs_ $ _retryWhen shouldRetry $ do
        modifyIORef counter succ
        n <- readIORef counter
        pure ("test response" :: String, n)
      logs `shouldBeM` [LogItem Warning [("span_github-api-retry", "true")] "(\"test response\",1)"]

  describe "_retryGithubRequest" $ do
    it "retries on timeouts" $ do
      counter <- newIORef (0 :: Int)
      Right result <- _retryGithubRequest $ do
        modifyIORef counter succ
        n <- readIORef counter
        if n <= 1
          then do
            request <- parseRequest "http://example.com"
            pure $ Left (GH.HTTPError (HttpExceptionRequest request ResponseTimeout))
          else pure $ Right ()
      result `shouldBeM` ()
      readIORef counter `shouldReturnM` 2
