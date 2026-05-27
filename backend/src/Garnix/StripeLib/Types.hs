module Garnix.StripeLib.Types where

import Data.Aeson (Options (constructorTagModifier), Value (..), camelTo2, defaultOptions, genericParseJSON, withText)
import Data.Map.Strict (Map)
import Data.Row (Rec, type (.+), type (.==))
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import GHC.TypeLits (KnownSymbol, symbolVal)
import Garnix.MonetaryCost
import Garnix.Prelude
import Garnix.Types
import Prelude qualified (Show (..))

newtype UnitAmount = UnitAmount {toDecimalInCents :: Text}
  deriving stock (Generic, Show, Eq)

unitAmountFromCost :: MonetaryCost -> UnitAmount
unitAmountFromCost = UnitAmount . show . getCostInCents

newtype Name = Name {getName :: Text}
  deriving stock (Generic, Show, Eq)
  deriving newtype (FromJSON, ToJSON)

newtype PriceId = PriceId {getPriceId :: Text}
  deriving stock (Generic, Show, Eq)
  deriving newtype (FromJSON, ToJSON, FromHttpApiData)

type CustomerDto =
  Rec
    ( "object" .== ConstString "customer"
        .+ "id" .== CustomerId
        .+ "name" .== Name
        .+ "email" .== Email
        .+ "metadata" .== Map Text Text
    )

type SubscriptionDto =
  Rec
    ( "object" .== ConstString "subscription"
        .+ "id" .== SubscriptionId
        .+ "customer" .== CustomerId
        .+ "latest_invoice" .== InvoiceDto
        .+ "pending_setup_intent" .== Value
        .+ "status" .== SubscriptionStatus
        .+ "description" .== Maybe Text
        .+ "metadata" .== Map Text Text
        .+ "current_period_start" .== UnixTimeStamp
        .+ "current_period_end" .== UnixTimeStamp
    )

type SubscriptionListDto =
  Rec
    ( "object" .== ConstString "list"
        .+ "data"
          .== [ Rec
                  ( "object" .== ConstString "subscription"
                      .+ "id" .== SubscriptionId
                  )
              ]
    )

data SubscriptionStatus
  = SubscriptionStatusIncomplete
  | SubscriptionStatusIncompleteExpired
  | SubscriptionStatusTrialing
  | SubscriptionStatusActive
  | SubscriptionStatusPastDue
  | SubscriptionStatusCanceled
  | SubscriptionStatusUnpaid
  | SubscriptionStatusPaused
  deriving (Generic, Show, Eq)

instance FromJSON SubscriptionStatus where
  parseJSON =
    genericParseJSON
      $ defaultOptions
        { constructorTagModifier = \constructor ->
            camelTo2 '_'
              $ fromMaybe (error $ "unexpected constructor prefix: " <> cs constructor)
              $ stripPrefix ("SubscriptionStatus" :: String) constructor
        }

type InvoiceDto =
  Rec
    ( "object" .== ConstString "invoice"
        .+ "id" .== InvoiceId
        .+ "payment_intent" .== PaymentIntentDto
    )

type PaymentIntentDto =
  Rec
    ( "object" .== ConstString "payment_intent"
        .+ "id" .== Text
        .+ "status" .== Text
        .+ "client_secret" .== ClientSecret
    )

newtype ClientSecret = ClientSecret Text
  deriving stock (Generic, Show, Eq)
  deriving newtype (FromJSON, ToJSON)

type PriceDto =
  Rec
    ( "id" .== PriceId
        .+ "currency" .== Text
        .+ "unit_amount" .== Int64
    )

type EventDto typ inner =
  Rec
    ( "object" .== ConstString "event"
        .+ "api_version" .== Text
        .+ "created" .== UnixTimeStamp
        .+ "type" .== typ
        .+ "request"
          .== Rec
                ( "id" .== Maybe Text
                    .+ "idempotency_key" .== Maybe Text
                )
        .+ "data"
          .== Rec
                ( "object" .== inner
                )
    )

type CustomerSubscriptionCreatedOrUpdatedEventDto =
  EventDto
    CustomerSubscriptionEventType
    ( Rec
        ( "customer" .== CustomerId
            .+ "items"
              .== Rec
                    ( "data"
                        .== [Rec ("price" .== Rec ("id" .== PriceId))]
                    )
            .+ "status"
              .== SubscriptionStatus
            .+ "current_period_start" .== UnixTimeStamp
            .+ "current_period_end" .== UnixTimeStamp
        )
    )

type InvoiceCreatedEventDto =
  EventDto
    (ConstString "invoice.created")
    ( Rec
        ( "id" .== InvoiceId
            .+ "customer" .== CustomerId
            .+ "billing_reason" .== InvoiceBillingReason
            .+ "period_start" .== UnixTimeStamp
            .+ "period_end" .== UnixTimeStamp
        )
    )

data InvoiceBillingReason
  = -- | A subscription advanced into a new period.
    SubscriptionCycle
  | -- | A new subscription was created.
    SubscriptionCreate
  | -- | Unhandled billing reason -- see `billing_reason` on stripe invoice object.
    OtherInvoiceBillingReason Text
  deriving stock (Show, Eq)

instance FromJSON InvoiceBillingReason where
  parseJSON = withText "InvoiceBillingReason" $ \case
    "subscription_create" -> pure SubscriptionCreate
    "subscription_cycle" -> pure SubscriptionCycle
    text -> pure $ OtherInvoiceBillingReason text

data CustomerSubscriptionEventType = Created | Updated
  deriving stock (Show, Eq)

instance FromJSON CustomerSubscriptionEventType where
  parseJSON = withText "CustomerSubscriptionEventType" $ \case
    "customer.subscription.created" -> pure Created
    "customer.subscription.updated" -> pure Updated
    text -> fail $ "unknown event type: " <> cs text

type AddressDto =
  Rec
    ( "line1" .== Text
        .+ "line2" .== Maybe Text
        .+ "city" .== Text
        .+ "state" .== Text
        .+ "postal_code" .== Text
        .+ "country" .== Text
    )

type TaxCalculationDto =
  Rec
    ( "object" .== ConstString "tax.calculation"
        .+ "id" .== Text
        .+ "currency" .== Text
        .+ "amount_total" .== Int64
        .+ "tax_breakdown"
          .== [ Rec
                  ( "amount" .== Int64
                      .+ "tax_rate_details"
                        .== Rec
                              ( "tax_type" .== Maybe Text
                              )
                  )
              ]
        .+ "customer_details"
          .== Rec
                ( "address" .== AddressDto
                )
    )

-- * JSON helpers

data ConstString (value :: Symbol) = ConstString
  deriving stock (Eq)

instance (KnownSymbol symbol) => Show (ConstString symbol) where
  show ConstString = symbolVal $ Proxy @symbol

instance (KnownSymbol symbol) => FromJSON (ConstString symbol) where
  parseJSON =
    let constString = symbolVal (Proxy @symbol)
     in withText ("ConstString " <> cs (show constString)) $ \text ->
          if text == cs constString
            then pure ConstString
            else fail $ "expected const string: " <> cs (show (symbolVal (Proxy @symbol))) <> ", got: " <> cs (show text)

instance (KnownSymbol symbol) => ToJSON (ConstString symbol) where
  toJSON ConstString = String $ cs $ symbolVal $ Proxy @symbol

-- Like UTCTime, but the json serialization is the number of seconds since epoch.
newtype UnixTimeStamp = UnixTimeStamp {getUnixTimeStamp :: UTCTime}
  deriving newtype (Eq)

instance Show UnixTimeStamp where
  show (UnixTimeStamp utcTime) = "<" <> Prelude.show utcTime <> ">"

instance FromJSON UnixTimeStamp where
  parseJSON value = do
    n :: Int64 <- parseJSON value
    pure $ UnixTimeStamp $ posixSecondsToUTCTime $ fromIntegral n
