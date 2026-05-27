module Garnix.PreludeSpec (spec) where

import Garnix.Prelude
import Streaming.Prelude qualified as S
import Test.Hspec

spec :: Spec
spec = do
  describe "slidingWindow'" $ do
    it "works" $ do
      fmap
        (fmap toList)
        ( S.toList_
            $ slidingWindow' 5
            $ S.each [[1, 2, 3], [4, 5], [6], [7, 8, 9, 10]]
        )
        `shouldReturn` [ [1 :: Int, 2, 3],
                         [1, 2, 3, 4, 5],
                         [2, 3, 4, 5, 6],
                         [6, 7, 8, 9, 10]
                       ]

  describe "uniq" $ do
    it "removes duplicate, neighboring elements" $ do
      uniq "abbc" `shouldBe` "abc"

    it "removes more than one duplicate" $ do
      uniq "abbcdde" `shouldBe` "abcde"
      uniq "abbbc" `shouldBe` "abc"

    it "does not remove duplicate, non-neighboring elements" $ do
      uniq "abbcb" `shouldBe` "abcb"

    it "leaves lists without duplicates unmodified" $ do
      uniq "abc" `shouldBe` "abc"
