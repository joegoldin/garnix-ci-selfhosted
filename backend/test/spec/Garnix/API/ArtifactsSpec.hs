module Garnix.API.ArtifactsSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Garnix.API.Artifacts
import Garnix.AccessToken (generateToken)
import Garnix.AccessToken.Types (AccessTokenScopes (..), getAccessTokenText)
import Garnix.DB qualified as DB
import Garnix.DB.Artifacts qualified as Artifacts
import Garnix.Monad
import Garnix.Prelude
import Garnix.TestHelpers (testBuild, truncateDBM)
import Garnix.TestHelpers.Monad (beforeM_, inM, shouldBeM, shouldReturnM, shouldThrowM)
import Garnix.Types
import Servant.Auth.Server (AuthResult (..))
import Test.Hspec
import "base64-bytestring" Data.ByteString.Base64 qualified as Base64

spec :: Spec
spec = do
  describe "Garnix.API.Artifacts" $ do
    describe "storage keys" $ do
      it "builds the zip and manifest keys from the store hash" $ do
        artifactZipKey "h" `shouldBe` "artifacts/h/all.zip"
        artifactManifestKey "h" `shouldBe` "artifacts/h/manifest.json"

    inM $ beforeM_ truncateDBM $ do
      it "builds file keys and rejects traversal or empty segments" $ do
        artifactFileKey "h" ["dir", "a.txt"] `shouldReturnM` "artifacts/h/files/dir/a.txt"
        artifactFileKey "h" ["..", "x"] `shouldThrowM` BadRequest "Invalid artifact file path"
        artifactFileKey "h" ["dir", "..", "x"] `shouldThrowM` BadRequest "Invalid artifact file path"
        artifactFileKey "h" ["dir", ""] `shouldThrowM` BadRequest "Invalid artifact file path"
        artifactFileKey "h" [] `shouldThrowM` BadRequest "Artifact file path cannot be empty"

      it "latest.zip redirects to the newest published artifact" $ withStore $ do
        b1 <- testBuild $ (repoUser .~ "o") . (repoName .~ "r") . (branch ?~ "main")
        b2 <- testBuild $ (repoUser .~ "o") . (repoName .~ "r") . (branch ?~ "main")
        Artifacts.upsertArtifact b1 "a" "h1" ArtifactPublic "published"
        Artifacts.upsertArtifact b2 "a" "h2" ArtifactPublic "published"
        _artifactsAPIZipLatest anonymous "o" "r" "main" "a"
          `shouldThrowM` RedirectFound "public://artifacts/h2/all.zip"
        _artifactsAPIManifestLatest anonymous "o" "r" "main" "a"
          `shouldThrowM` RedirectFound "public://artifacts/h2/manifest.json"
        _artifactsAPIFileLatest anonymous "o" "r" "main" "a" ["sub", "f.txt"]
          `shouldThrowM` RedirectFound "public://artifacts/h2/files/sub/f.txt"

      it "by-build downloads presign private-bucket artifacts" $ withStore $ do
        b <- testBuild identity
        Artifacts.upsertArtifact b "a" "h" ArtifactPrivate "published"
        admin <- sessionAs "artifacts-admin" Admin
        _artifactsAPIZipByBuild admin (b ^. id) "a"
          `shouldThrowM` RedirectFound "presigned://artifacts/h/all.zip"
        _artifactsAPIManifestByBuild admin (b ^. id) "a"
          `shouldThrowM` RedirectFound "presigned://artifacts/h/manifest.json"
        _artifactsAPIFileByBuild admin (b ^. id) "a" ["dir", "f.txt"]
          `shouldThrowM` RedirectFound "presigned://artifacts/h/files/dir/f.txt"

      it "allows anonymous downloads of public-bucket artifacts" $ withStore $ do
        b <- testBuild identity
        Artifacts.upsertArtifact b "a" "h" ArtifactPublic "published"
        _artifactsAPIZipByBuild anonymous (b ^. id) "a"
          `shouldThrowM` RedirectFound "public://artifacts/h/all.zip"

      it "hides private-bucket artifacts from anonymous callers (404-shaped)" $ withStore $ do
        b <- testBuild identity
        Artifacts.upsertArtifact b "a" "h" ArtifactPrivate "published"
        _artifactsAPIZipByBuild anonymous (b ^. id) "a"
          `shouldThrowM` NoSuchBuild (b ^. id)

      it "404s missing artifacts, failed publications, and missing latest rows" $ withStore $ do
        b <- testBuild identity
        Artifacts.upsertArtifact b "failed" "h" ArtifactPublic "failed"
        _artifactsAPIZipByBuild anonymous (b ^. id) "nope"
          `shouldThrowM` NoSuchBuild (b ^. id)
        _artifactsAPIZipByBuild anonymous (b ^. id) "failed"
          `shouldThrowM` NoSuchBuild (b ^. id)
        _artifactsAPIZipLatest anonymous "test-owner" "test-repo" "test-branch" "nope"
          `shouldThrowM` NotFound

      it "rejects path traversal through the download handlers" $ withStore $ do
        b <- testBuild identity
        Artifacts.upsertArtifact b "a" "h" ArtifactPublic "published"
        _artifactsAPIFileByBuild anonymous (b ^. id) "a" ["..", "x"]
          `shouldThrowM` BadRequest "Invalid artifact file path"

      it "404s everything when no artifact store is configured" $ do
        b <- testBuild identity
        Artifacts.upsertArtifact b "a" "h" ArtifactPublic "published"
        _artifactsAPIZipByBuild anonymous (b ^. id) "a" `shouldThrowM` NotFound
        _artifactsAPIListBuild anonymous (b ^. id) `shouldThrowM` NotFound
        admin <- sessionAs "artifacts-admin" Admin
        _artifactsAPILock admin (b ^. id) `shouldThrowM` NotFound

      it "lock/unlock requires admin and flips the build's rows" $ withStore $ do
        b <- testBuild identity
        Artifacts.upsertArtifact b "a" "h" ArtifactPublic "published"
        nonAdmin <- sessionAs "artifacts-user" FreeSubscription
        _artifactsAPILock anonymous (b ^. id) `shouldThrowM` Unauthorized
        _artifactsAPILock nonAdmin (b ^. id) `shouldThrowM` Unauthorized
        admin <- sessionAs "artifacts-admin" Admin
        void $ _artifactsAPILock admin (b ^. id)
        lockedRows <- Artifacts.getArtifactsForBuild (b ^. id)
        map Artifacts._artifactRowLocked lockedRows `shouldBeM` [True]
        void $ _artifactsAPIUnlock admin (b ^. id)
        unlockedRows <- Artifacts.getArtifactsForBuild (b ^. id)
        map Artifacts._artifactRowLocked unlockedRows `shouldBeM` [False]

      it "delete requires admin and removes the row" $ withStore $ do
        b <- testBuild identity
        Artifacts.upsertArtifact b "a" "h" ArtifactPublic "published"
        rows <- Artifacts.getArtifactsForBuild (b ^. id)
        rowId <- case rows of
          [row] -> pure $ Artifacts._artifactRowId row
          _ -> throw $ OtherError "expected exactly one artifact row"
        _artifactsAPIDelete anonymous rowId `shouldThrowM` Unauthorized
        admin <- sessionAs "artifacts-admin" Admin
        void $ _artifactsAPIDelete admin rowId
        Artifacts.getArtifactsForBuild (b ^. id) `shouldReturnM` []

      it "listings join object sizes and hide private rows from anonymous callers" $ withStore $ do
        b <- testBuild identity
        Artifacts.upsertArtifact b "pub" "h1" ArtifactPublic "published"
        Artifacts.upsertArtifact b "priv" "h2" ArtifactPrivate "published"
        Artifacts.insertArtifactObject "h1" ArtifactPublic 123 4
        anonDtos <- _artifactsAPIListBuild anonymous (b ^. id)
        map _artifactDtoName anonDtos `shouldBeM` ["pub"]
        admin <- sessionAs "artifacts-admin" Admin
        adminDtos <- _artifactsAPIListBuild admin (b ^. id)
        sort (map _artifactDtoName adminDtos) `shouldBeM` ["priv", "pub"]
        repoDtos <- _artifactsAPIListRepo anonymous "test-owner" "test-repo" (Just "test-branch")
        map (\dto -> (_artifactDtoName dto, _artifactDtoTotalSize dto, _artifactDtoFileCount dto)) repoDtos
          `shouldBeM` [("pub", 123, 4)]
        otherBranch <- _artifactsAPIListRepo anonymous "test-owner" "test-repo" (Just "other-branch")
        otherBranch `shouldBeM` []

      it "commit listing filters by the build's commit and hides private rows from anonymous callers" $ withStore $ do
        b1 <- testBuild $ gitCommit .~ "c1"
        b2 <- testBuild $ gitCommit .~ "c2"
        Artifacts.upsertArtifact b1 "pub" "h1" ArtifactPublic "published"
        Artifacts.upsertArtifact b1 "priv" "h2" ArtifactPrivate "published"
        Artifacts.upsertArtifact b2 "other" "h3" ArtifactPublic "published"
        anonDtos <- _artifactsAPIListCommit anonymous "test-owner" "test-repo" "c1"
        map _artifactDtoName anonDtos `shouldBeM` ["pub"]
        admin <- sessionAs "artifacts-admin" Admin
        adminDtos <- _artifactsAPIListCommit admin "test-owner" "test-repo" "c1"
        sort (map _artifactDtoName adminDtos) `shouldBeM` ["priv", "pub"]

      it "commit-counts counts published artifacts per commit" $ withStore $ do
        b1 <- testBuild $ gitCommit .~ "c1"
        b2 <- testBuild $ gitCommit .~ "c1"
        b3 <- testBuild $ gitCommit .~ "c2"
        Artifacts.upsertArtifact b1 "a" "h1" ArtifactPublic "published"
        Artifacts.upsertArtifact b2 "b" "h2" ArtifactPublic "published"
        Artifacts.upsertArtifact b3 "c" "h3" ArtifactPublic "failed"
        counts <- _artifactsAPICommitCounts anonymous "test-owner" "test-repo"
        map (\c -> (_artifactCommitCountCommit c, _artifactCommitCountCount c)) counts
          `shouldBeM` [("c1", 2)]

      it "404s the commit-scoped endpoints when no artifact store is configured" $ do
        b <- testBuild $ gitCommit .~ "c1"
        Artifacts.upsertArtifact b "a" "h" ArtifactPublic "published"
        _artifactsAPIListCommit anonymous "test-owner" "test-repo" "c1" `shouldThrowM` NotFound
        _artifactsAPICommitCounts anonymous "test-owner" "test-repo" `shouldThrowM` NotFound

      it "serializes ArtifactDto with the exact snake_case keys" $ withStore $ do
        b <- testBuild identity
        Artifacts.upsertArtifact b "a" "h" ArtifactPublic "published"
        dtos <- _artifactsAPIListBuild anonymous (b ^. id)
        dto <- case dtos of
          [dto] -> pure dto
          _ -> throw $ OtherError "expected exactly one artifact dto"
        case toJSON dto of
          Aeson.Object obj -> do
            sort (map Key.toText (KeyMap.keys obj))
              `shouldBeM` sort
                [ "id",
                  "build_id",
                  "repo_user",
                  "repo_name",
                  "branch",
                  "name",
                  "store_hash",
                  "status",
                  "locked",
                  "created_at",
                  "total_size",
                  "file_count"
                ]
            -- the frontend expects the hashid string, not a number:
            KeyMap.lookup "build_id" obj
              `shouldBeM` Just (Aeson.String (getHashId (getBuildId (b ^. id))))
          _ -> throw $ OtherError "ArtifactDto should serialize to an object"

      it "accepts a basic-auth access token with the api scope" $ withStore $ do
        b <- testBuild identity
        Artifacts.upsertArtifact b "a" "h" ArtifactPrivate "published"
        user <- DB.newUser (GhLogin "token-admin") (Email "token-admin@example.com") Admin True
        token <- generateToken (user ^. id) "artifacts-token" (AccessTokenScopes {cache = False, api = True})
        let session = artifactsAPI Indefinite (Just (basicAuthHeader "token-admin" (getAccessTokenText token)))
        _artifactsAPIZipByBuild session (b ^. id) "a"
          `shouldThrowM` RedirectFound "presigned://artifacts/h/all.zip"

      it "rejects access tokens without the api scope, and unknown logins" $ withStore $ do
        b <- testBuild identity
        Artifacts.upsertArtifact b "a" "h" ArtifactPrivate "published"
        user <- DB.newUser (GhLogin "token-user") (Email "token-user@example.com") Admin True
        token <- generateToken (user ^. id) "cache-token" (AccessTokenScopes {cache = True, api = False})
        let cacheOnly = artifactsAPI Indefinite (Just (basicAuthHeader "token-user" (getAccessTokenText token)))
        _artifactsAPIZipByBuild cacheOnly (b ^. id) "a" `shouldThrowM` InvalidAccessToken
        let unknownLogin = artifactsAPI Indefinite (Just (basicAuthHeader "nobody" "boo"))
        _artifactsAPIZipByBuild unknownLogin (b ^. id) "a" `shouldThrowM` InvalidAccessToken

-- | Handlers acting as an unauthenticated caller.
anonymous :: ArtifactsAPI (AsServerT M)
anonymous = artifactsAPI Indefinite Nothing

-- | Handlers acting as a (fresh) session user with the given subscription.
sessionAs :: GhLogin -> SubscriptionType -> M (ArtifactsAPI (AsServerT M))
sessionAs login sub = do
  user <- DB.newUser login (Email $ getGhLogin login <> "@example.com") sub True
  pure $ artifactsAPI (Authenticated (ApiSession user)) Nothing

basicAuthHeader :: Text -> Text -> Text
basicAuthHeader login password = "Basic " <> cs (Base64.encode (cs (login <> ":" <> password)))

-- | An in-memory 'ArtifactStore' good enough for the download API: URLs are
-- @public://\<key>@ and @presigned://\<key>@.
withStore :: M a -> M a
withStore = local (#artifactStore ?~ testArtifactStore)

testArtifactStore :: ArtifactStore
testArtifactStore =
  ArtifactStore
    { _artifactStorePutFile = \_ _ _ -> notNeeded,
      _artifactStorePutBytes = \_ _ _ -> notNeeded,
      _artifactStoreDeletePrefix = \_ _ -> notNeeded,
      _artifactStorePresignGet = \_ key -> pure $ "presigned://" <> key,
      _artifactStorePublicUrl = ("public://" <>)
    }
  where
    notNeeded :: M a
    notNeeded = throw $ OtherError "testArtifactStore: not needed by the API spec"
