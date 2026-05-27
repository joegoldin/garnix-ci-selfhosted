module Garnix.API.GhWebhooksSpec where

import Garnix.API.GhWebhooks (ghWebhookCheckSuite)
import Garnix.Monad
import Garnix.Monad.Async
import Garnix.Prelude
import Garnix.TestHelpers
import Garnix.TestHelpers.Monad
import Garnix.Types
import Test.Hspec hiding (shouldReturn, shouldThrow)

spec :: Spec
spec = inM $ aroundM_ suppressLogsWhenPassing $ do
  describe "GhWebhooks" $ do
    describe "/api/events/github" $ do
      it "ignores checkSuiteEvent if GitHub app is not Garnix app" $ do
        let event = defaultEvent & (checkSuite . app . _Just . id .~ 123)
        withMock #buildFlakeMock (\_ -> throw $ OtherError "Should not be called") $ do
          ghWebhookCheckSuite event >>= resolve
