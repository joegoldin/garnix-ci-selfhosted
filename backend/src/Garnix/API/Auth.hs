module Garnix.API.Auth where

import Control.Lens
import Data.Text qualified as T
import Garnix.AccessToken
import Garnix.AccessToken.Types
import Garnix.DB qualified as DB
import Garnix.Monad
import Garnix.ParseHttpBasicAuth
import Garnix.Prelude
import Garnix.Types hiding (login)
import GitHub qualified as GH
import Network.OAuth2 qualified as OA
import Servant.Auth.Server
  ( Auth,
    AuthResult (Authenticated),
    Cookie,
    JWT,
    acceptLogin,
    clearSession,
  )
import Servant.Auth.Server.Internal.JWT (makeJWT)
import Web.Cookie

data UserDto = UserDto
  { _userDtoUsername :: GhLogin,
    _userDtoEmail :: Email,
    _userDtoIsAdmin :: Bool
  }
  deriving stock (Generic)

instance ToJSON UserDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

whoAmIAPI :: AuthResult AuthJwtPayload -> M (Maybe UserDto)
whoAmIAPI (Authenticated ((^. #user) -> user)) = do
  pure
    $ Just
    $ UserDto
      (user ^. githubLogin)
      (user ^. email)
      (user ^. subscriptionType == Admin)
whoAmIAPI _ = pure Nothing

-- * Self-host mode login gate + admin mapping
--
-- In self-host mode the backend listens on 127.0.0.1 only and sits behind an
-- authenticating gateway (oauth2-proxy/Authentik) that injects the
-- @X-Auth-Request-Groups@ header on every browser request. The header is
-- therefore trustworthy, and it is the sole authority for who may log in and
-- who is an admin.

-- | Whether a login attempt is allowed to proceed. In self-host mode the
-- gateway must have injected the groups header; a request without it did not
-- come through the gateway and is rejected. Outside self-host mode logins are
-- always allowed here.
selfHostLoginAllowed :: Bool -> Maybe Text -> Bool
selfHostLoginAllowed selfHost mGroupsHeader = not selfHost || isJust mGroupsHeader

-- | Map the gateway's comma-separated groups header to a subscription type:
-- membership of the admin group grants 'Admin', everything else is
-- 'FreeSubscription'. Group names are trimmed of surrounding whitespace.
subscriptionTypeForGroups :: Text -> Maybe Text -> SubscriptionType
subscriptionTypeForGroups adminGroup mGroupsHeader =
  case mGroupsHeader of
    Just groups
      | adminGroup `elem` map T.strip (T.splitOn "," groups) -> Admin
    _ -> FreeSubscription

-- | Reject a login that did not come through the authenticating gateway when
-- running in self-host mode. A no-op otherwise.
requireSelfHostAuth :: Maybe Text -> M ()
requireSelfHostAuth mGroupsHeader = do
  selfHost <- view #selfHostMode
  unless (selfHostLoginAllowed selfHost mGroupsHeader)
    $ throw
    $ ForbiddenWithMessage "Login requires the authentication gateway."

-- | In self-host mode, recompute the user's subscription type from the gateway
-- groups header on every login and persist it, returning the user with the
-- updated subscription type so the freshly minted session reflects it. A no-op
-- outside self-host mode.
applySelfHostSubscription :: User -> Maybe Text -> M User
applySelfHostSubscription user mGroupsHeader = do
  selfHost <- view #selfHostMode
  if not selfHost
    then pure user
    else do
      adminGroup <- view #adminGroupName
      let sub = subscriptionTypeForGroups adminGroup mGroupsHeader
      DB.setSubscriptionType (user ^. id) sub
      pure $ user & subscriptionType .~ sub

data AuthJwtAPI route = AuthJwtAPI
  { jwt :: route :- Header "Authorization" Text :> Auth '[JWT, Cookie] AuthJwtPayload :> Post '[JSON] AuthJwtDto
  }
  deriving stock (Generic)

data AuthJwtDto = AuthJwtDto
  { token :: Text,
    expiresAt :: UTCTime
  }
  deriving stock (Generic)
  deriving anyclass (ToJSON)

authJwtAPI :: AuthJwtAPI (AsServerT M)
authJwtAPI =
  AuthJwtAPI
    { jwt = getJwt
    }

getJwt :: Maybe Text -> AuthResult AuthJwtPayload -> M AuthJwtDto
getJwt mAuthHeader authResult = do
  authHeader <- case (mAuthHeader, authResult) of
    (_, Authenticated _) -> throw $ ForbiddenWithMessage "Creating JWTs is only allowed with the api access tokens."
    (Nothing, _) -> throw $ UnauthorizedWithMessage "Missing Authorization header"
    (Just authHeader, _) -> pure authHeader
  (username, password) <- case parseBasicAuth authHeader of
    Left err -> throw $ BadRequest $ cs err
    Right creds -> pure creds
  user <-
    withError
      ( errLens %~ \case
          NoSuchUser _ -> Unauthorized
          err -> err
      )
      $ DB.getUser
      $ GhLogin username
  isValid <- isAccessTokenValid (user ^. id) (AccessToken password) (^. #api)
  when (not isValid) $ do
    throw Unauthorized
  jwtSettings' <- view #jwtSettings
  expiresAt <-
    liftIO getCurrentTime
      <&> addUTCTime 3600
  jwt <- liftIO $ makeJWT (ApiSession user) jwtSettings' (Just expiresAt)
  jwt <- case jwt of
    Left err -> throw $ OtherError $ "Failed to create JWT: " <> show err
    Right jwt -> pure jwt
  pure
    $ AuthJwtDto
      { token = cs jwt,
        expiresAt
      }

data LoginAPI route = LoginAPI
  { _loginAPILogin :: route :- Get '[JSON] LoginLinks,
    _loginAPILogout ::
      route
        :- Delete
             '[JSON]
             ( Headers
                 '[Header "Set-Cookie" SetCookie, Header "Set-Cookie" SetCookie]
                 ()
             ),
    _loginAPILoginCallback ::
      route
        :- "cb"
        :> QueryParam "code" OAuthCode
        :> Header "X-Auth-Request-Groups" Text
        :> Get
             '[JSON]
             ( Headers
                 '[ Header "Set-Cookie" SetCookie,
                    Header "Set-Cookie" SetCookie
                  ]
                 GhLogin
             )
  }
  deriving (Generic)

data SignupAPI route = SignupAPI
  { _signupAPISignup :: route :- Get '[JSON] SignupLinks,
    _signupAPISignupCallback ::
      route
        :- "fill"
        :> QueryParam "code" OAuthCode
        :> Header "X-Auth-Request-Groups" Text
        :> Get
             '[JSON]
             ( Headers
                 '[ Header "Set-Cookie" SetCookie,
                    Header "Set-Cookie" SetCookie
                  ]
                 (CreatingUser ())
             ),
    _signupAPIFinishSignup ::
      route
        :- Auth '[Cookie] (CreatingUser GhToken)
        :> ReqBody '[JSON] CreateUser
        :> Header "X-Auth-Request-Groups" Text
        :> Post
             '[JSON]
             ( Headers
                 '[ Header "Set-Cookie" SetCookie,
                    Header "Set-Cookie" SetCookie
                  ]
                 GhLogin
             )
  }
  deriving (Generic)

loginAPI :: LoginAPI (AsServerT M)
loginAPI =
  LoginAPI
    { _loginAPILogin = login,
      _loginAPILogout = logout,
      _loginAPILoginCallback = loginCallback
    }

signupAPI :: SignupAPI (AsServerT M)
signupAPI =
  SignupAPI
    { _signupAPISignup = signup,
      _signupAPISignupCallback = signupCallback,
      _signupAPIFinishSignup = finishSignup
    }

login :: M LoginLinks
login = do
  oaState <- OA.newOAuthState
  ghOauth <- githubOauthLogin
  githubLink <- OA.getAuthorize oaState ghOauth "foo"
  return $ LoginLinks {_loginLinksGithub = githubLink}

logout ::
  M
    ( Headers
        '[Header "Set-Cookie" SetCookie, Header "Set-Cookie" SetCookie]
        ()
    )
logout = do
  cookieSettings' <- view #cookieSettings
  return $ clearSession cookieSettings' ()

signup :: M SignupLinks
signup = do
  oaState <- OA.newOAuthState
  ghOauth <- githubOauthSignup
  githubLink <- OA.getAuthorize oaState ghOauth "foo"
  return
    $ SignupLinks
      { _signupLinksGithub = githubLink
      }

loginCallback ::
  Maybe OAuthCode ->
  Maybe Text ->
  M
    ( Headers
        '[Header "Set-Cookie" SetCookie, Header "Set-Cookie" SetCookie]
        GhLogin
    )
loginCallback code mGroupsHeader = do
  requireSelfHostAuth mGroupsHeader
  (login', _, token) <- callbackHelper githubOauthLogin code
  cookieSettings' <- view #cookieSettings
  jwtSettings' <- view #jwtSettings
  user <- DB.getUser login' <?> "calling getUser"
  user' <- applySelfHostSubscription user mGroupsHeader
  mApplyCookies <-
    liftIO (acceptLogin cookieSettings' jwtSettings' (WebSession user' token))
      <?> "calling acceptLogin"
  case mApplyCookies of
    Nothing -> throw Unauthorized
    Just applyCookies ->
      return
        $ applyCookies
        $ user'
        ^. githubLogin

signupCallback ::
  Maybe OAuthCode ->
  Maybe Text ->
  M
    ( Headers
        '[Header "Set-Cookie" SetCookie, Header "Set-Cookie" SetCookie]
        (CreatingUser ())
    )
signupCallback code mGroupsHeader = do
  requireSelfHostAuth mGroupsHeader
  (login', email', token) <- callbackHelper githubOauthSignup code
  eUser <- try $ DB.getUser login' <?> "calling getUser"
  creatingUser <- case eUser of
    Right _ ->
      pure
        $ CreatingUser
          { _creatingUserExists = True,
            _creatingUserGithubLogin = login',
            _creatingUserEmail = email',
            _creatingUserGithubToken = token
          }
    Left ErrorWithContext {err = NoSuchUser {}} ->
      pure
        $ CreatingUser
          { _creatingUserExists = False,
            _creatingUserGithubLogin = login',
            _creatingUserEmail = email',
            _creatingUserGithubToken = token
          }
    Left e -> throwError e
  cookieSettings' <- view #cookieSettings
  jwtSettings' <- view #jwtSettings
  mApplyCookies <- case eUser of
    Right user -> do
      user' <- applySelfHostSubscription user mGroupsHeader
      liftIO $ acceptLogin cookieSettings' jwtSettings' (WebSession user' token)
    _ -> liftIO $ acceptLogin cookieSettings' jwtSettings' creatingUser
  case mApplyCookies of
    Nothing -> throw Unauthorized
    Just applyCookies -> return $ applyCookies (void creatingUser)

callbackHelper :: M OA.OAuth2 -> Maybe OAuthCode -> M (GhLogin, Email, GhToken)
callbackHelper _ Nothing = throw $ OtherError "'code' param missing"
callbackHelper githubOauth (Just (OAuthCode code)) = do
  oaState <- OA.newOAuthState <?> "Creating new oauth state"
  ghOauth <- githubOauth
  mToken <-
    liftIO (OA.getAuthorized ghOauth oaState (Just code) Nothing)
      <?> "calling OA.getAuthorized"
  case mToken of
    Nothing -> throw GithubDidntGiveUsAToken
    Just (token, _) -> do
      let auth = GH.OAuth $ cs token
      eGhUser <- liftIO (GH.github auth GH.userInfoCurrentR) <?> "calling userInfoCurrentR"
      case eGhUser of
        Left e -> throw $ OtherError $ show e
        Right ghUser -> do
          e <- getEmail auth ghUser <?> "calling getEmail"
          pure
            ( GhLogin . GH.untagName $ GH.userLogin ghUser,
              e,
              GhToken $ cs token
            )
  where
    getEmail auth ghUser = case GH.userEmail ghUser of
      Just e -> pure $ Email e
      Nothing -> do
        emails <-
          liftIO (GH.github auth $ GH.currentUserEmailsR GH.FetchAll)
            <?> "calling currentUserEmailsR"
        case find GH.emailPrimary <$> emails of
          Right (Just e') -> pure $ Email $ GH.emailAddress e'
          _ -> throw $ OtherError "No email address"

finishSignup ::
  AuthResult (CreatingUser GhToken) ->
  CreateUser ->
  Maybe Text ->
  M (Headers '[Header "Set-Cookie" SetCookie, Header "Set-Cookie" SetCookie] GhLogin)
finishSignup (Authenticated cUser) addenda mGroupsHeader = do
  requireSelfHostAuth mGroupsHeader
  -- The things in AuthResult we can trust, because we put them there
  user <-
    DB.newUser
      (cUser ^. githubLogin)
      (addenda ^. email)
      (addenda ^. subscriptionType)
      (addenda ^. agreeToEmails)
  user' <- applySelfHostSubscription user mGroupsHeader
  cookieSettings' <- view #cookieSettings
  jwtSettings' <- view #jwtSettings
  mApplyCookies <- liftIO $ acceptLogin cookieSettings' jwtSettings' (WebSession user' (cUser ^. githubToken))
  case mApplyCookies of
    Nothing -> throw Unauthorized
    Just applyCookies -> return $ applyCookies $ user' ^. githubLogin
finishSignup _ _ _ = throw $ OtherError "Did not receive expected user info"

githubOauthLogin :: M OA.OAuth2
githubOauthLogin = do
  clientId <- view #githubClientId
  ghClientSecret <- view #githubClientSecret
  fromRelativeUrl <- relativeUrlConverter
  pure
    $ OA.OAuth2
      { oauthClientId = clientId,
        oauthClientSecret = ghClientSecret,
        oauthOAuthorizeEndpoint = "https://github.com/login/oauth/authorize",
        oauthAccessTokenEndpoint = "https://github.com/login/oauth/access_token",
        oauthCallback = fromRelativeUrl "login/cb",
        oauthScopes = []
      }

githubOauthSignup :: M OA.OAuth2
githubOauthSignup = do
  clientId <- view #githubClientId
  ghClientSecret <- view #githubClientSecret
  fromRelativeUrl <- relativeUrlConverter
  pure
    $ OA.OAuth2
      { oauthClientId = clientId,
        oauthClientSecret = ghClientSecret,
        oauthOAuthorizeEndpoint = "https://github.com/login/oauth/authorize",
        oauthAccessTokenEndpoint = "https://github.com/login/oauth/access_token",
        oauthCallback = fromRelativeUrl "signup/fill",
        oauthScopes = []
      }
