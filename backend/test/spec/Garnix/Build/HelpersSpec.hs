module Garnix.Build.HelpersSpec (spec) where

import Garnix.Build.Helpers (cacheHostFromUrl)
import Garnix.Prelude
import Test.Hspec

spec :: Spec
spec = describe "cacheHostFromUrl" $ do
  it "strips the https:// scheme from a plain URL" $
    cacheHostFromUrl "https://cache.garnix.io" `shouldBe` "cache.garnix.io"

  it "drops a trailing slash" $
    cacheHostFromUrl "https://mycache.example.com/" `shouldBe` "mycache.example.com"

  it "drops a path segment" $
    cacheHostFromUrl "https://cache.example.com/foo/bar" `shouldBe` "cache.example.com"

  it "strips the http:// scheme" $
    cacheHostFromUrl "http://cache.example.com" `shouldBe` "cache.example.com"
