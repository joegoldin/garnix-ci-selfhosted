module Garnix.ParseHttpBasicAuth where

import Data.ByteString.Base64
import Data.Text qualified as T
import Garnix.Prelude

parseBasicAuth :: Text -> Either String (Text, Text)
parseBasicAuth authHeader = do
  b64 <- case T.stripPrefix "Basic " authHeader of
    Just x -> Right x
    Nothing -> Left "Auth request missing `Basic ` prefix"
  credentials <- decode $ cs b64
  case T.splitOn ":" $ cs credentials of
    user : password | not (null password) -> Right (user, T.intercalate ":" password)
    _ -> Left "No `:` in decoded payload"
