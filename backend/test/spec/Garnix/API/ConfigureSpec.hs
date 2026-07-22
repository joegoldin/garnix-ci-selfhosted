module Garnix.API.ConfigureSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Lens (key, _String)
import Garnix.API.Configure
import Garnix.DB qualified as DB
import Garnix.DB.Artifacts qualified as Artifacts
import Garnix.Monad (ArtifactBucket (..), M, throw)
import Garnix.Prelude
import Garnix.TestHelpers (testBuild, truncateDBM)
import Garnix.TestHelpers.Monad
  ( beforeM_,
    inM,
    shouldBeM,
    shouldContainM,
    shouldReturnM,
    shouldThrowM,
  )
import Garnix.Types
import Servant.Auth.Server (AuthResult (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "Garnix.API.Configure (domains)" $ inM $ beforeM_ truncateDBM $ do
    it "lists configured and manual domains once with durable status"
      $ local
        ( (#hostingDomain .~ "configured.example")
            . (#extraHostingDomains .~ ["extra.example"])
        )
      $ asAdmin
      $ \api -> do
        manualId <- DB.addConnectedDomain "manual.example" True
        duplicateId <- DB.addConnectedDomain "extra.example" True
        DB.markConnectedDomainVerified duplicateId
        DB.markConfiguredDomainVerified "configured.example"

        domains <- _configureAPIListDomains api

        map
          ( \domain ->
              ( _connectedDomainDtoId domain,
                _connectedDomainDtoDomain domain,
                _connectedDomainDtoVerified domain,
                _connectedDomainDtoNixConfigured domain
              )
          )
          domains
          `shouldBeM` [ (Nothing, "configured.example", True, True),
                        (Nothing, "extra.example", False, True),
                        (Just manualId, "manual.example", False, False)
                      ]

    it "persists successful configured-domain verification and rejects other names"
      $ local
        ( (#hostingDomain .~ "configured.example")
            . (#extraHostingDomains .~ [])
        )
      $ do
        verified <- __verifyConfiguredDomain (const $ pure True) "configured.example"
        _connectedDomainDtoVerified verified `shouldBeM` True

        stillVerified <- __verifyConfiguredDomain (const $ pure False) "configured.example"
        _connectedDomainDtoVerified stillVerified `shouldBeM` True

        __verifyConfiguredDomain
          (const $ throw $ OtherError "resolver must not run")
          "not-configured.example"
          `shouldThrowM` (OtherError "Domain is not Nix-configured")

    it "rejects non-admin callers on configured-domain routes"
      $ local (#hostingDomain .~ "configured.example")
      $ asUser FreeSubscription
      $ \api -> do
        _configureAPIListDomains api `shouldThrowM` Unauthorized
        _configureAPIVerifyConfiguredDomain api (AddDomainDto "configured.example")
          `shouldThrowM` Unauthorized

  describe "Garnix.API.Configure (artifacts)" $ inM $ beforeM_ truncateDBM $ do
    it "roundtrips the default artifact settings through the handlers" $ asAdmin $ \api -> do
      _configureAPISetArtifactDefaults api (SetArtifactDefaultsDto 7 True)
        `shouldReturnM` NoContent
      dto <- _configureAPIGet api
      _configureSettingsDtoArtifactRetentionDays dto `shouldBeM` 7
      _configureSettingsDtoArtifactKeepLatest dto `shouldBeM` True
      -- server_settings isn't truncated between tests: restore the defaults.
      _configureAPISetArtifactDefaults api (SetArtifactDefaultsDto 30 False)
        `shouldReturnM` NoContent
      restored <- _configureAPIGet api
      _configureSettingsDtoArtifactRetentionDays restored `shouldBeM` 30
      _configureSettingsDtoArtifactKeepLatest restored `shouldBeM` False

    it "sets, lists, and clears per-repo artifact overrides" $ asAdmin $ \api -> do
      _configureAPISetArtifactRepo api "some-owner" "some-repo" (SetArtifactRepoDto (Just 90) Nothing)
        `shouldReturnM` NoContent
      dto <- _configureAPIGet api
      _configureSettingsDtoArtifactRepoOverrides dto
        `shouldBeM` [ ArtifactRepoOverrideDto
                        { _artifactRepoOverrideDtoRepoUser = "some-owner",
                          _artifactRepoOverrideDtoRepoName = "some-repo",
                          _artifactRepoOverrideDtoRetentionDays = Just 90,
                          _artifactRepoOverrideDtoKeepLatest = Nothing
                        }
                    ]
      _configureAPIDeleteArtifactRepo api "some-owner" "some-repo"
        `shouldReturnM` NoContent
      cleared <- _configureAPIGet api
      _configureSettingsDtoArtifactRepoOverrides cleared `shouldBeM` []

    it "reflects seeded usage and locked builds in the settings dto" $ asAdmin $ \api -> do
      b1 <- testBuild identity
      b2 <- testBuild identity
      -- Two rows sharing one content-addressed object: its size counts once.
      Artifacts.upsertArtifact b1 "skills" "shared-hash" ArtifactPublic "published"
      Artifacts.upsertArtifact b2 "skills" "shared-hash" ArtifactPublic "published"
      Artifacts.insertArtifactObject "shared-hash" ArtifactPublic 100 1
      Artifacts.setBuildArtifactsLocked (b2 ^. id) True
      dto <- _configureAPIGet api
      _configureSettingsDtoArtifactUsage dto
        `shouldBeM` [ArtifactUsageDto "test-owner" "test-repo" 100]
      map
        ( \locked ->
            ( _lockedArtifactBuildDtoBuildId locked,
              _lockedArtifactBuildDtoRepoUser locked,
              _lockedArtifactBuildDtoRepoName locked,
              _lockedArtifactBuildDtoBranch locked,
              _lockedArtifactBuildDtoName locked
            )
        )
        (_configureSettingsDtoLockedArtifactBuilds dto)
        `shouldBeM` [(b2 ^. id, "test-owner", "test-repo", Just "test-branch", "skills")]

    it "emits the JSON contract the frontend expects" $ asAdmin $ \api -> do
      build <- testBuild identity
      Artifacts.upsertArtifact build "skills" "some-hash" ArtifactPublic "published"
      Artifacts.insertArtifactObject "some-hash" ArtifactPublic 100 2
      Artifacts.setBuildArtifactsLocked (build ^. id) True
      Artifacts.setRepoArtifactSettings "some-owner" "some-repo" (Just 90) (Just True)
      dto <- _configureAPIGet api
      let topKeys = jsonKeys (toJSON dto)
      forM_
        ( [ "artifact_retention_days",
            "artifact_keep_latest",
            "artifact_repo_overrides",
            "artifact_usage",
            "locked_artifact_builds"
          ] ::
            [Aeson.Key]
        )
        $ \k -> topKeys `shouldContainM` [k]
      map toJSON (_configureSettingsDtoArtifactRepoOverrides dto)
        `shouldBeM` [ [aesonQQ| {
                        repo_user: "some-owner",
                        repo_name: "some-repo",
                        retention_days: 90,
                        keep_latest: true
                      } |]
                    ]
      map toJSON (_configureSettingsDtoArtifactUsage dto)
        `shouldBeM` [ [aesonQQ| {
                        repo_user: "test-owner",
                        repo_name: "test-repo",
                        total_size: 100
                      } |]
                    ]
      -- created_at is the row's server-side now(), so check the key set and
      -- that build_id serializes as the usual hashid string.
      let lockedJson = map toJSON (_configureSettingsDtoLockedArtifactBuilds dto)
      map jsonKeys lockedJson
        `shouldBeM` [["branch", "build_id", "created_at", "name", "repo_name", "repo_user"]]
      map (^? key "build_id" . _String) lockedJson
        `shouldBeM` [Just (getHashId (getBuildId (build ^. id)))]

    it "rejects non-admin callers on the artifact routes" $ asUser FreeSubscription $ \api -> do
      _configureAPISetArtifactDefaults api (SetArtifactDefaultsDto 7 True)
        `shouldThrowM` Unauthorized
      _configureAPISetArtifactRepo api "o" "r" (SetArtifactRepoDto (Just 1) Nothing)
        `shouldThrowM` Unauthorized
      _configureAPIDeleteArtifactRepo api "o" "r"
        `shouldThrowM` Unauthorized

-- | The configure handlers demand self-host mode plus an admin caller; run
-- the inner action against a handler record built for an admin.
asAdmin :: (ConfigureAPI (AsServerT M) -> M a) -> M a
asAdmin = asUser Admin

asUser :: SubscriptionType -> (ConfigureAPI (AsServerT M) -> M a) -> M a
asUser subscription f = do
  now <- liftIO getCurrentTime
  let user =
        User
          { _userId = UserId 1,
            _userGithubLogin = GhLogin "configure-spec",
            _userEmail = Email "configure-spec@example.com",
            _userSubscriptionType = subscription,
            _userCreatedAt = now
          }
  local (#selfHostMode .~ True)
    $ f
    $ configureAPI
    $ Authenticated
    $ ApiSession user

jsonKeys :: Aeson.Value -> [Aeson.Key]
jsonKeys = \case
  Aeson.Object o -> sort (KeyMap.keys o)
  _ -> []
