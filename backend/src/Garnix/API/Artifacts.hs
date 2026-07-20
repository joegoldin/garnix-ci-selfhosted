-- | Download + management API for build artifacts (garnix.yaml @artifacts:@):
-- listings for the web UI, download endpoints that 302 to storage (stable
-- URLs into the public bucket, short-lived presigned URLs for the private
-- one), and admin-only lock\/unlock\/delete management.
--
-- Auth: public-bucket rows are anonymous; private-bucket rows need a session
-- user or a basic-auth access token (@api@ scope) with access to the repo.
-- Access failures are 404-shaped (like 'NoSuchBuild') to avoid existence
-- leaks. The whole API 404s when no 'ArtifactStore' is configured.
module Garnix.API.Artifacts
  ( ArtifactsAPI (..),
    artifactsAPI,
    ArtifactDto (..),
    ArtifactCommitCount (..),
    Get302,
    authorizeArtifact,
    artifactZipKey,
    artifactManifestKey,
    artifactFileKey,
  )
where

import Data.Aeson qualified as Aeson
import Data.Text qualified as T
import Garnix.API.Admin (requireAdmin)
import Garnix.Access (hasAccessToRepo)
import Garnix.AccessToken (isAccessTokenValid)
import Garnix.AccessToken.Types (AccessToken (..))
import Garnix.Artifacts (ArtifactManifest)
import Garnix.DB qualified as DB
import Garnix.DB.Artifacts
import Garnix.Monad
import Garnix.ParseHttpBasicAuth (parseBasicAuth)
import Garnix.Prelude
import Garnix.Types
import Servant (CaptureAll)
import Servant.Auth.Server (AuthResult (..))

-- | The download endpoints reply with a 302 redirect, implemented by throwing
-- 'RedirectFound' (which "Garnix.Types" maps to a 302 with a @location@
-- header), so the declared 'NoContent' body is never produced.
type Get302 = Get '[JSON] NoContent

data ArtifactsAPI route = ArtifactsAPI
  { _artifactsAPIListRepo ::
      route
        :- "repo"
          :> Capture "owner" GhRepoOwner
          :> Capture "repo" GhRepoName
          :> QueryParam "branch" Branch
          :> Get '[JSON] [ArtifactDto],
    _artifactsAPIListBuild ::
      route
        :- "build"
          :> Capture "buildId" BuildId
          :> Get '[JSON] [ArtifactDto],
    _artifactsAPICommitCounts ::
      route
        :- "repo"
          :> Capture "owner" GhRepoOwner
          :> Capture "repo" GhRepoName
          :> "commit-counts"
          :> Get '[JSON] [ArtifactCommitCount],
    _artifactsAPIListCommit ::
      route
        :- "commit"
          :> Capture "owner" GhRepoOwner
          :> Capture "repo" GhRepoName
          :> Capture "commit" CommitHash
          :> Get '[JSON] [ArtifactDto],
    _artifactsAPIZipByBuild ::
      route
        :- "build"
          :> Capture "buildId" BuildId
          :> Capture "name" Text
          :> "all.zip"
          :> Get302,
    _artifactsAPIManifestByBuild ::
      route
        :- "build"
          :> Capture "buildId" BuildId
          :> Capture "name" Text
          :> "manifest"
          :> Get302,
    -- | Same manifest as '_artifactsAPIManifestByBuild', returned inline
    -- (200, JSON body) instead of a 302 to storage. The redirect target is
    -- cross-origin with no CORS headers, which a browser's @fetch@ can't
    -- follow; this route exists for the file-browser UI to call directly.
    _artifactsAPIManifestJsonByBuild ::
      route
        :- "build"
          :> Capture "buildId" BuildId
          :> Capture "name" Text
          :> "manifest.json"
          :> Get '[JSON] ArtifactManifest,
    _artifactsAPIFileByBuild ::
      route
        :- "build"
          :> Capture "buildId" BuildId
          :> Capture "name" Text
          :> "files"
          :> CaptureAll "path" Text
          :> Get302,
    _artifactsAPIZipLatest ::
      route
        :- Capture "owner" GhRepoOwner
          :> Capture "repo" GhRepoName
          :> Capture "branch" Branch
          :> Capture "name" Text
          :> "latest.zip"
          :> Get302,
    _artifactsAPIManifestLatest ::
      route
        :- Capture "owner" GhRepoOwner
          :> Capture "repo" GhRepoName
          :> Capture "branch" Branch
          :> Capture "name" Text
          :> "latest"
          :> "manifest"
          :> Get302,
    _artifactsAPIFileLatest ::
      route
        :- Capture "owner" GhRepoOwner
          :> Capture "repo" GhRepoName
          :> Capture "branch" Branch
          :> Capture "name" Text
          :> "latest"
          :> "files"
          :> CaptureAll "path" Text
          :> Get302,
    _artifactsAPILock ::
      route
        :- "build"
          :> Capture "buildId" BuildId
          :> "lock"
          :> Post '[JSON] NoContent,
    _artifactsAPIUnlock ::
      route
        :- "build"
          :> Capture "buildId" BuildId
          :> "lock"
          :> Delete '[JSON] NoContent,
    _artifactsAPIDelete ::
      route
        :- Capture "artifactId" Int64
          :> Delete '[JSON] NoContent
  }
  deriving (Generic)

-- | An artifact row for the web UI. Serializes with snake_case keys via
-- 'ourToJSON' (@id@, @build_id@, @repo_user@, @repo_name@, @branch@, @name@,
-- @store_hash@, @status@, @locked@, @created_at@, @total_size@,
-- @file_count@); @build_id@ serializes as the hashid string.
data ArtifactDto = ArtifactDto
  { _artifactDtoId :: Int64,
    _artifactDtoBuildId :: BuildId,
    _artifactDtoRepoUser :: GhRepoOwner,
    _artifactDtoRepoName :: GhRepoName,
    _artifactDtoBranch :: Maybe Branch,
    _artifactDtoName :: Text,
    _artifactDtoStoreHash :: Text,
    _artifactDtoStatus :: Text,
    _artifactDtoLocked :: Bool,
    _artifactDtoCreatedAt :: UTCTime,
    _artifactDtoTotalSize :: Int64,
    _artifactDtoFileCount :: Int
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ArtifactDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

-- | A commit's published-artifact count, for the repo build-list page's
-- per-row badge. Serializes with snake_case keys via 'ourToJSON' (@commit@,
-- @count@).
data ArtifactCommitCount = ArtifactCommitCount
  { _artifactCommitCountCommit :: CommitHash,
    _artifactCommitCountCount :: Int64
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ArtifactCommitCount where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

toArtifactDto :: ArtifactDtoRow -> ArtifactDto
toArtifactDto row =
  ArtifactDto
    { _artifactDtoId = _artifactDtoRowId row,
      _artifactDtoBuildId = _artifactDtoRowBuildId row,
      _artifactDtoRepoUser = _artifactDtoRowRepoUser row,
      _artifactDtoRepoName = _artifactDtoRowRepoName row,
      _artifactDtoBranch = _artifactDtoRowBranch row,
      _artifactDtoName = _artifactDtoRowName row,
      _artifactDtoStoreHash = _artifactDtoRowStoreHash row,
      _artifactDtoStatus = _artifactDtoRowStatus row,
      _artifactDtoLocked = _artifactDtoRowLocked row,
      _artifactDtoCreatedAt = _artifactDtoRowCreatedAt row,
      _artifactDtoTotalSize = _artifactDtoRowTotalSize row,
      _artifactDtoFileCount = _artifactDtoRowFileCount row
    }

artifactsAPI :: AuthResult AuthJwtPayload -> Maybe Text -> ArtifactsAPI (AsServerT M)
artifactsAPI auth authHeader =
  ArtifactsAPI
    { _artifactsAPIListRepo = \owner repo mBranch -> do
        void requireArtifactStore
        rows <- getArtifactDtosForRepo owner repo mBranch
        visibleArtifacts auth authHeader rows,
      _artifactsAPIListBuild = \buildId -> do
        void requireArtifactStore
        rows <- getArtifactDtosForBuild buildId
        visibleArtifacts auth authHeader rows,
      _artifactsAPICommitCounts = \owner repo -> do
        void requireArtifactStore
        counts <- getArtifactCommitCountsForRepo owner repo
        pure $ map (uncurry ArtifactCommitCount) counts,
      _artifactsAPIListCommit = \owner repo commit -> do
        void requireArtifactStore
        rows <- getArtifactDtosForCommit owner repo commit
        visibleArtifacts auth authHeader rows,
      _artifactsAPIZipByBuild = \buildId name ->
        serveByBuild buildId name (pure . artifactZipKey),
      _artifactsAPIManifestByBuild = \buildId name ->
        serveByBuild buildId name (pure . artifactManifestKey),
      _artifactsAPIManifestJsonByBuild = \buildId name -> do
        (store, row) <- resolvePublishedBuildArtifact buildId name
        authorizeArtifact auth authHeader row
        let key = artifactManifestKey (_artifactRowStoreHash row)
        bytes <- _artifactStoreGetBytes store (_artifactRowBucket row) key
        either (throw . OtherError . ("corrupt artifact manifest: " <>) . cs) pure
          $ Aeson.eitherDecode' bytes,
      _artifactsAPIFileByBuild = \buildId name path ->
        serveByBuild buildId name (`artifactFileKey` path),
      _artifactsAPIZipLatest = \owner repo branch' name ->
        serveLatest owner repo branch' name (pure . artifactZipKey),
      _artifactsAPIManifestLatest = \owner repo branch' name ->
        serveLatest owner repo branch' name (pure . artifactManifestKey),
      _artifactsAPIFileLatest = \owner repo branch' name path ->
        serveLatest owner repo branch' name (`artifactFileKey` path),
      _artifactsAPILock = (`setLocked` True),
      _artifactsAPIUnlock = (`setLocked` False),
      _artifactsAPIDelete = \artifactId -> do
        void requireArtifactStore
        requireAdmin auth
        deleteArtifactRow artifactId
        pure NoContent
    }
  where
    -- | Look up a build's named artifact, requiring the artifact store to be
    -- configured and the row to be @published@ (404-shaped otherwise, same as
    -- a missing row — avoids existence leaks for failed publications).
    resolvePublishedBuildArtifact :: BuildId -> Text -> M (ArtifactStore, ArtifactRow)
    resolvePublishedBuildArtifact buildId name = do
      store <- requireArtifactStore
      mRow <- getArtifactByBuildAndName buildId name
      row <- case mRow of
        Just row | _artifactRowStatus row == "published" -> pure row
        _ -> throw $ NoSuchBuild buildId
      pure (store, row)

    serveByBuild :: BuildId -> Text -> (Text -> M Text) -> M NoContent
    serveByBuild buildId name keyFor = do
      (store, row) <- resolvePublishedBuildArtifact buildId name
      serveRow store row keyFor

    serveLatest :: GhRepoOwner -> GhRepoName -> Branch -> Text -> (Text -> M Text) -> M NoContent
    serveLatest owner repo branch' name keyFor = do
      store <- requireArtifactStore
      -- getLatestArtifact only returns published rows.
      mRow <- getLatestArtifact owner repo branch' name
      row <- case mRow of
        Just row -> pure row
        Nothing -> throw NotFound
      serveRow store row keyFor

    serveRow :: ArtifactStore -> ArtifactRow -> (Text -> M Text) -> M NoContent
    serveRow store row keyFor = do
      authorizeArtifact auth authHeader row
      key <- keyFor (_artifactRowStoreHash row)
      url <- case _artifactRowBucket row of
        ArtifactPublic -> pure $ _artifactStorePublicUrl store key
        ArtifactPrivate -> _artifactStorePresignGet store ArtifactPrivate key
      throw $ RedirectFound url

    setLocked :: BuildId -> Bool -> M NoContent
    setLocked buildId locked = do
      void requireArtifactStore
      requireAdmin auth
      setBuildArtifactsLocked buildId locked
      pure NoContent

-- | The artifacts feature is off (no @S3_ARTIFACTS_*@ config): 404 everything.
requireArtifactStore :: M ArtifactStore
requireArtifactStore =
  view #artifactStore >>= \case
    Just store -> pure store
    Nothing -> throw NotFound

-- | Filter a listing to what the caller may see: public-bucket rows always,
-- private-bucket rows only with access to the repo. Both listing queries are
-- scoped to a single repo, so one access check covers every private row.
visibleArtifacts :: AuthResult AuthJwtPayload -> Maybe Text -> [ArtifactDtoRow] -> M [ArtifactDto]
visibleArtifacts auth authHeader rows =
  case filter isPrivate rows of
    [] -> pure $ map toArtifactDto rows
    privateRow : _ -> do
      mUser <- resolveDownloadUser auth authHeader
      allowed <-
        hasAccessToRepo
          mUser
          (RepoIsPublic False)
          (_artifactDtoRowRepoUser privateRow)
          (_artifactDtoRowRepoName privateRow)
      pure $ map toArtifactDto $ if allowed then rows else filter (not . isPrivate) rows
  where
    isPrivate row = _artifactDtoRowBucket row == ArtifactPrivate

-- | Public-bucket rows: anonymous OK. Private: the session user, or the
-- basic-auth access token's user (@api@ scope), must have access to the
-- artifact's repo. Failure is a 404 ('NoSuchBuild'-style), not a 403, to
-- avoid existence leaks.
authorizeArtifact :: AuthResult AuthJwtPayload -> Maybe Text -> ArtifactRow -> M ()
authorizeArtifact auth authHeader row = case _artifactRowBucket row of
  ArtifactPublic -> pure ()
  ArtifactPrivate -> do
    mUser <- resolveDownloadUser auth authHeader
    allowed <-
      hasAccessToRepo
        mUser
        (RepoIsPublic False)
        (_artifactRowRepoUser row)
        (_artifactRowRepoName row)
    unless allowed $ throw $ NoSuchBuild $ _artifactRowBuildId row

-- | The user a request acts as: the JWT\/cookie session user when present,
-- else the user of a basic-auth access token in the @authorization@ header.
resolveDownloadUser :: AuthResult AuthJwtPayload -> Maybe Text -> M (Maybe User)
resolveDownloadUser (Authenticated payload) _ = pure $ Just $ payload ^. #user
resolveDownloadUser _ (Just authHeader) = Just <$> accessTokenUser authHeader
resolveDownloadUser _ Nothing = pure Nothing

-- | Resolve a basic-auth header to its user: the username is the gh login,
-- the password an access token with the @api@ scope (netrc-compatible, same
-- user-lookup + validation machinery as the binary cache's auth).
accessTokenUser :: Text -> M User
accessTokenUser authHeader = do
  (login, pass) <- case parseBasicAuth authHeader of
    Left err -> throw $ UnauthorizedWithMessage $ "Failed to parse basic auth: " <> show err
    Right credentials -> pure credentials
  let ghLogin = GhLogin login
  userId <- DB.getUserId ghLogin `catchError` \_ -> throw InvalidAccessToken
  isValid <- isAccessTokenValid userId (AccessToken pass) (^. #api)
  unless isValid $ throw InvalidAccessToken
  DB.getUser ghLogin

-- * Storage keys

-- | @artifacts/\<hash>/all.zip@ — the artifact's zipped output.
artifactZipKey :: Text -> Text
artifactZipKey storeHash = artifactKeyPrefix storeHash <> "all.zip"

-- | @artifacts/\<hash>/manifest.json@ — the artifact's file manifest.
artifactManifestKey :: Text -> Text
artifactManifestKey storeHash = artifactKeyPrefix storeHash <> "manifest.json"

-- | @artifacts/\<hash>/files/\<path>@ — a single artifact file. Rejects empty
-- paths and @..@\/empty segments with a 400: the path is spliced into a
-- storage URL.
artifactFileKey :: Text -> [Text] -> M Text
artifactFileKey storeHash path = do
  when (null path) $ throw $ BadRequest "Artifact file path cannot be empty"
  forM_ path $ \segment ->
    when (segment == ".." || T.null segment)
      $ throw
      $ BadRequest "Invalid artifact file path"
  pure $ artifactKeyPrefix storeHash <> "files/" <> T.intercalate "/" path

artifactKeyPrefix :: Text -> Text
artifactKeyPrefix storeHash = "artifacts/" <> storeHash <> "/"
