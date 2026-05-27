module Garnix.Password
  ( HashedPassword,
    hashPassword,
    validatePassword,
  )
where

import Data.ByteString (ByteString)
import Garnix.Prelude
import "crypton" Crypto.KDF.BCrypt qualified

newtype HashedPassword = HashedPassword ByteString
  deriving stock (Eq, Show, Generic)
  deriving newtype (PGParameter "text", PGColumn "text")

hashPassword :: (MonadIO m) => Text -> m HashedPassword
hashPassword plainTextPassword = do
  hashed :: ByteString <- liftIO $ Crypto.KDF.BCrypt.hashPassword 8 (cs plainTextPassword :: ByteString)
  pure $ HashedPassword hashed

validatePassword :: HashedPassword -> Text -> Bool
validatePassword (HashedPassword hashedPassword) plainTextPassword =
  Crypto.KDF.BCrypt.validatePassword (cs plainTextPassword :: ByteString) hashedPassword
