module Garnix.Monad.Bubbling where

import Control.Exception.Safe qualified as SafeException
import Garnix.Monad
import Garnix.Prelude

withBubbling ::
  (Typeable e, Show e) =>
  ((forall a. Either e a -> M a) -> M o) ->
  M (Either e o)
withBubbling action = do
  let bubble = \case
        Right a -> pure a
        Left error -> SafeException.throwIO (BubblingError error)
  SafeException.handle
    (\(BubblingError error) -> pure $ Left error)
    (Right <$> action bubble)

data BubblingError e = BubblingError e
  deriving stock (Show)

instance (Typeable e, Show e) => Exception (BubblingError e)
