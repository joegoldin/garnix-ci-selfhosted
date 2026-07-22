module Garnix.API.AdminSpec (spec) where

import Garnix.API.Admin
import Garnix.DB qualified as DB
import Garnix.Monad (M)
import Garnix.Prelude
import Garnix.TestHelpers (truncateDBM)
import Garnix.TestHelpers.Monad
import Garnix.Types
import Servant.Auth.Server (AuthResult (..))
import Test.Hspec

spec :: Spec
spec =
  describe "external-fork private-input approval API" $ inM $ beforeM_ truncateDBM $ do
    it "lists only recorded blocks and roundtrips allow/revoke" $ do
      DB.ensureRepoPrivateCache "automatic" "repo"
      DB.recordPrivateInputForkBlock "blocked" "repo"

      asAdmin $ \api -> do
        _adminAPISetPrivateInputForkApproval
          api
          "automatic"
          "repo"
          (SetPrivateInputForkApprovalDto True)
          `shouldReturnM` NoContent
        automaticConfig <- DB.getRepoConfig "automatic" "repo"
        automaticConfig ^. skipPrivateInputsCheckForCollaborators `shouldBeM` False

        requests <- _adminAPIListPrivateInputForkRequests api
        fmap requestSummary requests
          `shouldBeM` [("blocked", "repo", False)]

        _adminAPISetPrivateInputForkApproval
          api
          "blocked"
          "repo"
          (SetPrivateInputForkApprovalDto True)
          `shouldReturnM` NoContent
        approved <- _adminAPIListPrivateInputForkRequests api
        fmap requestSummary approved
          `shouldBeM` [("blocked", "repo", True)]

        _adminAPISetPrivateInputForkApproval
          api
          "blocked"
          "repo"
          (SetPrivateInputForkApprovalDto False)
          `shouldReturnM` NoContent
        revoked <- _adminAPIListPrivateInputForkRequests api
        fmap requestSummary revoked
          `shouldBeM` [("blocked", "repo", False)]

    it "rejects non-admin callers"
      $ asUser FreeSubscription
      $ \api -> do
        _adminAPIListPrivateInputForkRequests api `shouldThrowM` Unauthorized
        _adminAPISetPrivateInputForkApproval
          api
          "blocked"
          "repo"
          (SetPrivateInputForkApprovalDto True)
          `shouldThrowM` Unauthorized

requestSummary :: PrivateInputForkRequestDto -> (GhRepoOwner, GhRepoName, Bool)
requestSummary request =
  ( _privateInputForkRequestDtoRepoUser request,
    _privateInputForkRequestDtoRepoName request,
    _privateInputForkRequestDtoAllowed request
  )

asAdmin :: (AdminAPI (AsServerT M) -> M a) -> M a
asAdmin = asUser Admin

asUser :: SubscriptionType -> (AdminAPI (AsServerT M) -> M a) -> M a
asUser subscription f = do
  now <- liftIO getCurrentTime
  let user =
        User
          { _userId = UserId 1,
            _userGithubLogin = GhLogin "admin-spec",
            _userEmail = Email "admin-spec@example.com",
            _userSubscriptionType = subscription,
            _userCreatedAt = now
          }
  f $ adminAPI $ Authenticated $ ApiSession user
