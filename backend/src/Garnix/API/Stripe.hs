module Garnix.API.Stripe where

import Data.Aeson (Value)
import Data.ByteString.Lazy qualified
import Garnix.API.Account qualified as Account
import Garnix.Monad
import Garnix.Prelude
import Garnix.StripeLib qualified as StripeLib
import Network.HTTP.Types (hContentType)
import Network.Wai qualified as Wai
import Servant
import Servant.API.ContentTypes (canHandleCTypeH)
import Servant.Server.Internal.Delayed (Delayed, addBodyCheck)
import Servant.Server.Internal.DelayedIO (DelayedIO, delayedFail, delayedFailFatal, withRequest)
import Servant.Server.Internal.Router (Router)
import Stripe.Concepts qualified
import Stripe.Signature (isSigValid, parseSig)

type StripeWebhookAPI = StripeWebhookEvent :> Post '[JSON] ()

stripeWebhookAPI :: ServerT StripeWebhookAPI M
stripeWebhookAPI body = do
  parsedEvent <- StripeLib.fromWebhookRequest body
  case parsedEvent of
    Just (StripeLib.SubscriptionCreatedOrUpdated event) -> Account.handleSubscriptionAdded event
    Just (StripeLib.InvoiceCreated event) -> Account.handleInvoiceCreated event
    Nothing -> return ()

data StripeWebhookEvent

instance
  (HasServer api context, HasContextEntry context Stripe.Concepts.WebhookSecretKey) =>
  HasServer (StripeWebhookEvent :> api) context
  where
  type ServerT (StripeWebhookEvent :> api) m = Value -> ServerT api m

  hoistServerWithContext Proxy pc nt s = hoistServerWithContext (Proxy :: Proxy api) pc nt . s

  route :: Proxy (StripeWebhookEvent :> api) -> Context context -> Delayed env (Server (StripeWebhookEvent :> api)) -> Router env
  route Proxy context subServer =
    route (Proxy :: Proxy api) context
      $ addBodyCheck subServer (withRequest contentTypeCheck) (\f -> withRequest $ bodyCheck f)
    where
      contentTypeCheck request =
        let contentType = fromMaybe "application/octet-stream" $ lookup hContentType $ Wai.requestHeaders request
         in case canHandleCTypeH (Proxy :: Proxy '[JSON]) (cs contentType) of
              Nothing -> delayedFail err415
              Just f -> return f
      bodyCheck :: (Data.ByteString.Lazy.ByteString -> Either String Value) -> Wai.Request -> DelayedIO Value
      bodyCheck f request = do
        case lookup "Stripe-Signature" (Wai.requestHeaders request) >>= parseSig . cs of
          Nothing -> delayedFailFatal err401
          Just stripeSignature -> do
            body <- liftIO $ Wai.lazyRequestBody request
            let webhookSecret :: Stripe.Concepts.WebhookSecretKey = getContextEntry context
            if isSigValid stripeSignature webhookSecret (cs body)
              then case f body of
                Left err -> delayedFailFatal err400 {errBody = cs err}
                Right value -> return value
              else delayedFailFatal err401
