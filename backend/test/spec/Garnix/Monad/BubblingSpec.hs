module Garnix.Monad.BubblingSpec where

import Garnix.Monad
import Garnix.Monad.Bubbling
import Garnix.Prelude
import Garnix.TestHelpers.Monad
import Test.Hspec

spec :: Spec
spec = do
  inM $ describe "withBubbling" $ do
    it "allows letting Lefts of Eithers bubble up" $ do
      let innerThrowing :: M (Either Text ())
          innerThrowing = pure $ Left "test error"
      let outerBubbling :: M (Either Text Bool)
          outerBubbling = withBubbling $ \bubble -> do
            () <- bubble =<< innerThrowing
            pure True
      outerBubbling `shouldReturnM` Left "test error"

    it "will let Rights through normally" $ do
      let innerThrowing :: M (Either Text Int)
          innerThrowing = pure $ Right 2
      let outerBubbling :: M (Either Text Text)
          outerBubbling = withBubbling $ \bubble -> do
            n <- bubble =<< innerThrowing
            pure $ show $ n + 3
      outerBubbling `shouldReturnM` Right "5"

    it "does nothing when not using bubbling" $ do
      let outerBubbling :: M (Either Text Text)
          outerBubbling = withBubbling $ \_bubble -> do
            pure "foo"
      outerBubbling `shouldReturnM` Right "foo"
