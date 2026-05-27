{-# LANGUAGE OverloadedLabels #-}

module Garnix.StripeLibSpec where

import Control.Arrow ((>>>))
import Control.Lens
import Control.Monad.Extra (mapMaybeM)
import Data.Aeson
import Data.Row
import Garnix.Duration
import Garnix.Monad
import Garnix.Prelude hiding (get)
import Garnix.StripeLib
import Garnix.TestHelpers
import Garnix.TestHelpers.Monad (withDevSecrets)
import Garnix.Types
import Network.Wreq (FormParam (..))
import Test.Hspec

runAgainstStripeTestApi :: M a -> IO a
runAgainstStripeTestApi action = do
  runTestM
    $ withDevSecrets
    $ withUnmock #createCustomerMock
    $ withUnmock #createInvoiceItemMock
    $ withUnmock #createSubscriptionMock
    $ withUnmock #listSubscriptionsMock
    $ withUnmock #cancelSubscriptionMock action

spec :: Spec
spec = describe "Stripe @slow" $ do
  describe "createCustomer" $ do
    it "creates a customer" $ runAgainstStripeTestApi $ do
      customer <- createCustomer "alicesmith" (Name "Alice Smith") (Email "test@example.com")
      liftIO $ (customer ^. #name) `shouldBe` Name "Alice Smith"
      liftIO $ (customer ^. #email) `shouldBe` Email "test@example.com"
      liftIO $ (customer ^. #metadata) `shouldBe` "github_account" ~> "alicesmith"

  describe "createSubscription" $ do
    it "creates a subscription" $ runAgainstStripeTestApi $ do
      c <- createCustomer "alicesmith" (Name "Alice Smith") (Email "test@example.com")
      sub <- createSubscription (c ^. #id) testPriceId "test-product" "some description"
      liftIO $ (sub ^. #customer) `shouldBe` c ^. #id
      liftIO $ (sub ^. #description) `shouldBe` Just "some description"
      liftIO $ (sub ^. #metadata) `shouldBe` "product" ~> "test-product"

  describe "listSubscriptions" $ do
    it "lists subscriptions" $ runAgainstStripeTestApi $ do
      c <- createCustomer "alicesmith" (Name "Alice Smith") (Email "test@example.com")
      sub <- createSubscription (c ^. #id) testPriceId "test-product" "some description"
      subs <- listSubscriptions (c ^. #id)
      liftIO $ (subs ^.. #data . traverse . #id) `shouldBe` [sub ^. #id]

    it "does not list cancelled subscriptions" $ runAgainstStripeTestApi $ do
      c <- createCustomer "alicesmith" (Name "Alice Smith") (Email "test@example.com")
      sub <- createSubscription (c ^. #id) testPriceId "test-product" "some description"
      cancelSubscription (sub ^. #id)
      subs <- listSubscriptions (c ^. #id)
      liftIO $ (subs ^.. #data . traverse . #id) `shouldBe` []

  describe "taxCalculation" $ do
    let addressInCalifornia :: AddressDto =
          #line1 .== "548 Market Street"
            .+ #line2 .== Just "PMB 31001"
            .+ #city .== "San Francisco"
            .+ #state .== "California"
            .+ #postal_code .== "94104"
            .+ #country .== "US"
    it "calculates the tax" $ runAgainstStripeTestApi $ do
      calc <- taxCalculation 1234 "usd" addressInCalifornia
      liftIO $ do
        (calc ^. #customer_details . #address) `shouldBe` addressInCalifornia
        let taxBreakdown = calc ^. #tax_breakdown
            totalTax = sum $ map (^. #amount) taxBreakdown
        totalTax `shouldSatisfy` (>= 0)
        (calc ^. #amount_total) `shouldBe` 1234 + totalTax
        (calc ^. #currency) `shouldBe` "usd"
        fromSingleton taxBreakdown ^. #tax_rate_details . #tax_type `shouldBe` Just "sales_tax"

  describe "fromWebhookRequest" $ do
    it "returns Nothing for unknown events" $ runAgainstStripeTestApi $ do
      parsed <- fromWebhookRequest [aesonQQ| { "object": "event", "type": "unknown" } |]
      liftIO $ parsed `shouldBe` Nothing

    it "errors for known events that cannot be parsed" $ runAgainstStripeTestApi $ do
      parsed <-
        try
          $ fromWebhookRequest
            [aesonQQ|
              {
                "api_version": "test-version",
                "created": 1715107747,
                "object": "event",
                "type": "customer.subscription.created",
                "data": {
                  "object": "unparseable"
                }
              }
            |]
      liftIO $ first (err >>> message) parsed `shouldBe` Left "expected REC: {current_period_end,current_period_start,customer,items,status}, but encountered String"

    it "errors for things that aren't events" $ runAgainstStripeTestApi $ do
      parsed <- try $ fromWebhookRequest [aesonQQ| { "object": "something-else" } |]
      liftIO $ first (err >>> message) parsed `shouldBe` Left "expected const string: \"event\", got: \"something-else\""

    it "converts a real stripe event for a paid subscription" $ runAgainstStripeTestApi $ do
      c <- createCustomer "alicesmith" (Name "Alice Smith") (Email "test@example.com")
      sub <- createSubscription (c ^. #id) testPriceId "test-product" "some description"
      let piId = sub ^. #latest_invoice . #payment_intent . #id
      _ :: PaymentIntentDto <-
        post
          ("/payment_intents/" <> piId <> "/confirm")
          ["payment_method" := ("pm_card_visa" :: Text)]
      waitFor (fromSeconds @Int 5) $ do
        -- To test our webhook parsing, we retrieve events from `/events` instead of having the webhook events be delivered somehow.
        events :: StripeListPage Value <- get "/events"
        events <-
          mapMaybeM fromWebhookRequest (events ^. #data)
            <&> filter
              ( \case
                  SubscriptionCreatedOrUpdated (SubscriptionCreatedOrUpdatedEvent _ customer _ _ _ _) -> customer == c ^. #id
                  InvoiceCreated (InvoiceCreatedEvent customer _ _ _ _) -> customer == c ^. #id
              )
        liftIO $ length events `shouldBe` 3
        let [ SubscriptionCreatedOrUpdated (SubscriptionCreatedOrUpdatedEvent Updated updatedCustomerId updatedTestPriceId SubscriptionStatusActive _ _),
              SubscriptionCreatedOrUpdated (SubscriptionCreatedOrUpdatedEvent Created createdCustomerId createdTestPriceId SubscriptionStatusIncomplete _ _),
              InvoiceCreated (InvoiceCreatedEvent invoiceCustomerId _ billingReason _ _)
              ] = events
        liftIO $ do
          updatedCustomerId `shouldBe` c ^. #id
          updatedTestPriceId `shouldBe` testPriceId
          createdCustomerId `shouldBe` c ^. #id
          createdTestPriceId `shouldBe` testPriceId
          invoiceCustomerId `shouldBe` c ^. #id
          billingReason `shouldBe` SubscriptionCreate

testPriceId :: PriceId
testPriceId = PriceId "price_1PB26jATmop1ibwYk3blno4n"
