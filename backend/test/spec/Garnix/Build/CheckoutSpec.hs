module Garnix.Build.CheckoutSpec (spec) where

import Cradle
import Garnix.Build.Checkout
import Garnix.Monad
import Garnix.Prelude
import Garnix.TestHelpers.Monad
import System.IO.Temp
import Test.Hspec

spec :: Spec
spec = inM $ describe "cleanRemote" $ do
  it "should remove tokens from the origin remote" $ suppressLogsWhenPassing $ do
    withSystemTempDirectory "cleanRemoteTest"
      $ \tmp -> local (#workingDir .~ tmp) $ do
        let unclean = "https://x-access-token:foo@github.com/bar/baz.git"
        () <-
          run
            $ cmd "git"
            & addArgs ["init" :: Text]
            & setWorkingDir tmp
        () <-
          run
            $ cmd "git"
            & addArgs
              [ "remote" :: Text,
                "add",
                "origin",
                unclean
              ]
            & setWorkingDir tmp
        cleanRemote (RemoteUrl unclean)
        (StdoutTrimmed out) <-
          run
            $ cmd "git"
            & addArgs
              [ "remote" :: Text,
                "get-url",
                "origin"
              ]
            & setWorkingDir tmp
        out `shouldBeM` "https://github.com/bar/baz.git"
