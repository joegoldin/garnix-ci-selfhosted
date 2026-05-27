module Garnix.AttributeSpec (spec) where

import Data.Text qualified as T
import Garnix.Attribute
import Garnix.Prelude
import Garnix.YamlConfig
import Test.Hspec

spec :: Spec
spec = do
  describe "matches" $ do
    it "matches itself" $ do
      eg1 `shouldMatch` eg1
      eg2 `shouldMatch` eg2
      eg3 `shouldMatch` eg3

    it "does not match something different" $ do
      eg1 `shouldNotMatch` eg2
      eg1 `shouldNotMatch` eg3
      eg2 `shouldNotMatch` eg1
      eg2 `shouldNotMatch` eg3
      eg3 `shouldNotMatch` eg1
      eg3 `shouldNotMatch` eg2
      eg3 `shouldNotMatch` eg2

    it "matches the wildcard" $ do
      forM_ [eg1, eg2, eg3] $ \eg ->
        forM_ (replaceWithWildcard eg) $ \m ->
          eg `shouldMatch` m

  describe "mightMatch" $ do
    it "matches if LHS is a prefix" $ do
      eg4 `shouldMaybeMatch` eg1

    it "does not match if RHS is a prefix" $ do
      eg1 `shouldntMaybeMatch` eg4

    it "does not match itself" $ do
      eg1 `shouldntMaybeMatch` eg1
      eg2 `shouldntMaybeMatch` eg2
      eg3 `shouldntMaybeMatch` eg3
      eg4 `shouldntMaybeMatch` eg4

-- * Examples

eg1, eg2, eg3, eg4 :: Text
eg1 = "packages.x86_64-linux.foo"
eg2 = "checks.aarch-darwin.bar"
eg3 = "defaultPackage.aarch-darwin"
eg4 = "packages.x86_64-linux"

-- * Expectations

shouldMatch :: Text -> Text -> Expectation
shouldMatch = shouldMatch' matches

shouldNotMatch :: Text -> Text -> Expectation
shouldNotMatch = shouldMatch' (\x y -> not (x `matches` y))

shouldMaybeMatch :: Text -> Text -> Expectation
shouldMaybeMatch = shouldMatch' mightMatch

shouldntMaybeMatch :: Text -> Text -> Expectation
shouldntMaybeMatch = shouldMatch' (\x y -> not (x `mightMatch` y))

-- * Helpers

replaceWithWildcard :: Text -> [Text]
replaceWithWildcard attr =
  T.tail
    <$> foldM (\a b -> [a <> "." <> b, a <> ".*"]) "" (T.splitOn "." attr)

shouldMatch' :: (Attribute -> AttributeMatcher -> Bool) -> Text -> Text -> Expectation
shouldMatch' matchingFn attr matcher = case attr ^? asAttribute of
  Just a -> case parseAttributeMatcher matcher of
    Left _ -> expectationFailure $ "Could not parse matcher: " <> cs matcher
    Right m
      | a `matchingFn` m -> pure ()
      | otherwise ->
          expectationFailure
            $ "Expected "
            <> cs attr
            <> " to match "
            <> cs matcher
  Nothing -> expectationFailure $ "Could not parse attribute: " <> cs attr
