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
    it "lists only recorded fork blocks and roundtrips allow/revoke" $ do
      DB.ensureRepoPrivateCache "automatic" "repo"
      DB.recordPrivateInputForkBlock "blocked" "repo" (PrFromFork "forkowner/fork")

      asAdmin $ \api -> do
        -- A repo with only an automatic private cache (no recorded fork block)
        -- never appears here, and approving a fork request that does not exist
        -- is a no-op that leaves the repo-wide flag untouched.
        _adminAPISetPrivateInputForkApproval
          api
          "automatic"
          "repo"
          (SetPrivateInputForkApprovalDto True "someone/fork")
          `shouldReturnM` NoContent
        automaticConfig <- DB.getRepoConfig "automatic" "repo"
        automaticConfig ^. skipPrivateInputsCheckForCollaborators `shouldBeM` False

        requests <- _adminAPIListPrivateInputForkRequests api
        fmap requestSummary requests
          `shouldBeM` [("blocked", "repo", "forkowner/fork", False)]

        _adminAPISetPrivateInputForkApproval
          api
          "blocked"
          "repo"
          (SetPrivateInputForkApprovalDto True "forkowner/fork")
          `shouldReturnM` NoContent
        approved <- _adminAPIListPrivateInputForkRequests api
        fmap requestSummary approved
          `shouldBeM` [("blocked", "repo", "forkowner/fork", True)]

        -- Per-fork approval must not set the repo-wide collaborator-skip flag.
        blockedConfig <- DB.getRepoConfig "blocked" "repo"
        blockedConfig ^. skipPrivateInputsCheckForCollaborators `shouldBeM` False

        _adminAPISetPrivateInputForkApproval
          api
          "blocked"
          "repo"
          (SetPrivateInputForkApprovalDto False "forkowner/fork")
          `shouldReturnM` NoContent
        revoked <- _adminAPIListPrivateInputForkRequests api
        fmap requestSummary revoked
          `shouldBeM` [("blocked", "repo", "forkowner/fork", False)]

    it "approves each fork of a repo independently" $ do
      DB.recordPrivateInputForkBlock "owner" "repo" (PrFromFork "forkA/fork")
      DB.recordPrivateInputForkBlock "owner" "repo" (PrFromFork "forkB/fork")

      asAdmin $ \api -> do
        _adminAPISetPrivateInputForkApproval
          api
          "owner"
          "repo"
          (SetPrivateInputForkApprovalDto True "forkA/fork")
          `shouldReturnM` NoContent
        requests <- _adminAPIListPrivateInputForkRequests api
        -- Approving fork A leaves fork B of the same base repo still blocked.
        sort (fmap requestSummary requests)
          `shouldBeM` sort
            [ ("owner", "repo", "forkA/fork", True),
              ("owner", "repo", "forkB/fork", False)
            ]

    it "rejects non-admin callers"
      $ asUser FreeSubscription
      $ \api -> do
        _adminAPIListPrivateInputForkRequests api `shouldThrowM` Unauthorized
        _adminAPISetPrivateInputForkApproval
          api
          "blocked"
          "repo"
          (SetPrivateInputForkApprovalDto True "forkowner/fork")
          `shouldThrowM` Unauthorized

requestSummary :: PrivateInputForkRequestDto -> (GhRepoOwner, GhRepoName, Text, Bool)
requestSummary request =
  ( _privateInputForkRequestDtoRepoUser request,
    _privateInputForkRequestDtoRepoName request,
    _privateInputForkRequestDtoForkFullName request,
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
