module Garnix.AccessToken
  ( isAccessTokenValid,
    generateToken,
  )
where

import Control.Monad.Extra
import Garnix.AccessToken.Types
import Garnix.DB qualified as DB
import Garnix.Monad
import Garnix.Password
import Garnix.Prelude
import Garnix.Types

generateToken :: UserId -> Text -> AccessTokenScopes -> M AccessToken
generateToken userId name scopes = do
  token <- AccessToken <$> randomBase64 30
  hashedToken <- hashPassword $ getAccessTokenText token
  DB.insertAccessTokenForUser userId name scopes hashedToken
  pure token

isAccessTokenValid :: UserId -> AccessToken -> (AccessTokenScopes -> Bool) -> M Bool
isAccessTokenValid userId token checkScopes = do
  accessTokenHashes <- DB.getAccessTokenHashesForUser userId
  flip anyM accessTokenHashes $ \(tokenId, hash, scopes) -> do
    let isValid = checkScopes scopes && validatePassword hash (getAccessTokenText token)
    when isValid $ DB.markAccessTokenUsed userId tokenId
    pure isValid
