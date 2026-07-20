-- | Build-artifact publish pipeline: walks a build's output, uploads
-- content-addressed objects through the 'Garnix.Monad.ArtifactStore', and
-- records rows via "Garnix.DB.Artifacts".
--
-- Objects are keyed by the output's nix store hash, so re-publishing the same
-- content (e.g. a rebuilt commit with an unchanged output) uploads nothing
-- new. Under @artifacts\/\<storeHash\>\/@ each object consists of the
-- individual files (@files\/\<relative path\>@, symlinks dereferenced), a
-- deterministic @all.zip@, and a @manifest.json@ describing the contents.
module Garnix.Artifacts
  ( ManifestFile (..),
    ArtifactManifest (..),
    publishArtifacts,

    -- * exported for tests
    walkOutput,
    buildArtifactZip,
    publishOutput,
  )
where

import Codec.Archive.Zip qualified as Zip
import Crypto.Hash (SHA256 (..), hashWith)
import Data.Aeson qualified as Aeson
import Data.Bits (shiftL)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Char (isAlphaNum)
import Data.Text qualified as T
import Garnix.DB qualified as GarnixDB
import Garnix.DB.Artifacts qualified as DB
import Garnix.Monad
import Garnix.Nix.StorePath (withStorePath)
import Garnix.Nix.Types qualified as Nix
import Garnix.Prelude
import Garnix.Types
import Garnix.YamlConfig (ArtifactSection, GarnixConfig, artifactDisplayName, artifacts)
import System.Directory (canonicalizePath, doesDirectoryExist, doesPathExist, executable, getFileSize, getPermissions, listDirectory, pathIsSymbolicLink)
import System.IO.Temp (withSystemTempDirectory)

-- | One file of a published artifact, as described in @manifest.json@.
-- Symlinks are dereferenced at publish time, so every entry is a regular file.
data ManifestFile = ManifestFile
  { _manifestFilePath :: Text,
    _manifestFileSize :: Int64,
    _manifestFileSha256 :: Text,
    _manifestFileExecutable :: Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ManifestFile where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

-- | Parses the same @manifest.json@ shape 'ToJSON' produces: used to read a
-- manifest back after fetching its bytes from storage (see
-- @Garnix.API.Artifacts@'s inline @manifest.json@ route).
instance FromJSON ManifestFile where
  parseJSON = ourParseJSON

-- | The @manifest.json@ uploaded next to an artifact's files and @all.zip@.
data ArtifactManifest = ArtifactManifest
  { _artifactManifestFiles :: [ManifestFile],
    _artifactManifestTotalSize :: Int64,
    _artifactManifestFileCount :: Int,
    _artifactManifestStoreHash :: Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ArtifactManifest where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

instance FromJSON ArtifactManifest where
  parseJSON = ourParseJSON

-- | Publish the artifacts a repo's garnix.yaml declares, from the finished
-- builds of one commit. A no-op when no 'ArtifactStore' is configured. A
-- failing publication never throws: it is logged and recorded as a @failed@
-- row instead, so one broken artifact doesn't fail the whole build flow.
publishArtifacts :: GarnixConfig -> [Build] -> M ()
publishArtifacts config builds =
  view #artifactStore >>= \case
    Nothing -> pure ()
    Just store -> forM_ (config ^. artifacts) $ \section -> do
      let wanted b =
            b ^. package == section ^. package
              && b ^. packageType == TypePackage
              && b ^. status == Just Success
      forM_ (filter wanted builds) $ \build ->
        publishOne store section build `catchEither` \e -> do
          log Warning $ "Publishing artifact " <> artifactDisplayName section <> " failed: " <> show e
          bucket <- bucketFor build
          DB.upsertArtifact build (artifactDisplayName section) "" bucket "failed"

-- | Publish one artifact section for one successful build: resolve the
-- build's @out@ store path (held under a GC root while uploading) and upload
-- its contents. Throws on invalid names and missing store paths — the caller
-- turns that into a @failed@ row.
publishOne :: ArtifactStore -> ArtifactSection -> Build -> M ()
publishOne store section build = do
  let artifactName = artifactDisplayName section
  unless (isValidArtifactName artifactName)
    $ throw
    $ OtherError
    $ "invalid artifact name: "
    <> artifactName
    <> " (allowed: [a-zA-Z0-9._-]+)"
  withStorePath build "out" $ \case
    Nothing ->
      throw $ OtherError $ "no \"out\" store path for build " <> show (build ^. id)
    Just storePath ->
      publishOutput store build artifactName (cs (Nix.getHash storePath)) (cs storePath)

-- | Upload an output directory as the content-addressed object @storeHash@
-- (skipped entirely when the object already exists) and record the artifact
-- row. Exported for tests, which pass a directory instead of resolving a real
-- store path.
publishOutput :: ArtifactStore -> Build -> Text -> Text -> FilePath -> M ()
publishOutput store build artifactName storeHash outputPath = do
  bucket <- bucketFor build
  let prefix = "artifacts/" <> storeHash <> "/"
  unlessM (DB.artifactObjectExists storeHash bucket) $ do
    walked <- liftIO $ walkOutput outputPath
    entries <- case walked of
      Left err -> throw $ OtherError $ "walking artifact output " <> cs outputPath <> ": " <> err
      Right entries -> pure entries
    manifestFiles <- forM entries $ \(rel, resolved, size, exec) -> do
      _artifactStorePutFile store bucket (prefix <> "files/" <> cs rel) resolved
      contents <- liftIO $ BS.readFile resolved
      pure
        ManifestFile
          { _manifestFilePath = cs rel,
            _manifestFileSize = size,
            _manifestFileSha256 = show (hashWith SHA256 contents),
            _manifestFileExecutable = exec
          }
    archive <- liftIO $ buildArtifactZip entries
    withSystemTempDirectory "garnix-artifact" $ \tempDir -> do
      let zipPath = tempDir </> "all.zip"
      liftIO $ BSL.writeFile zipPath $ Zip.fromArchive archive
      _artifactStorePutFile store bucket (prefix <> "all.zip") zipPath
    let manifest =
          ArtifactManifest
            { _artifactManifestFiles = manifestFiles,
              _artifactManifestTotalSize = sum [size | (_, _, size, _) <- entries],
              _artifactManifestFileCount = length entries,
              _artifactManifestStoreHash = storeHash
            }
    _artifactStorePutBytes store bucket (prefix <> "manifest.json") (Aeson.encode manifest)
    DB.insertArtifactObject storeHash bucket (_artifactManifestTotalSize manifest) (length entries)
  DB.upsertArtifact build artifactName storeHash bucket "published"

-- | Same rule as the binary cache ('Garnix.S3Cache.upload'): private repos —
-- and public repos that opted into a private cache — publish to the private
-- (presigned-URL) bucket.
bucketFor :: Build -> M ArtifactBucket
bucketFor build = do
  repoConfig <- GarnixDB.getRepoConfig (build ^. repoUser) (build ^. repoName)
  let usePrivate = not (isRepoPublic (build ^. repoIsPublic)) || (repoConfig ^. privateCache)
  pure $ if usePrivate then ArtifactPrivate else ArtifactPublic

isValidArtifactName :: Text -> Bool
isValidArtifactName artifactName =
  not (T.null artifactName)
    && T.all (\c -> isAlphaNum c || c `elem` ("._-" :: String)) artifactName

-- | Recursively walk an output directory, returning
-- @(relative path, resolved absolute path, size in bytes, executable)@ per
-- regular file, sorted by relative path. Symlinks (to files and directories)
-- are dereferenced; a dangling symlink fails the whole walk with 'Left', as
-- does a root that is not a directory.
walkOutput :: FilePath -> IO (Either Text [(FilePath, FilePath, Int64, Bool)])
walkOutput root = runExceptT $ do
  isDir <- liftIO $ doesDirectoryExist root
  unless isDir $ throwError $ cs root <> " is not a directory"
  sortOn (\(rel, _, _, _) -> rel) <$> go ""
  where
    go :: FilePath -> ExceptT Text IO [(FilePath, FilePath, Int64, Bool)]
    go relDir = do
      let dir = if null relDir then root else root </> relDir
      names <- liftIO $ listDirectory dir
      children <- forM names (walkEntry relDir)
      pure $ concat children

    walkEntry :: FilePath -> FilePath -> ExceptT Text IO [(FilePath, FilePath, Int64, Bool)]
    walkEntry relDir entryName = do
      let rel = if null relDir then entryName else relDir </> entryName
      resolved <- resolve rel (root </> rel)
      isDir <- liftIO $ doesDirectoryExist resolved
      if isDir
        then go rel
        else do
          size <- liftIO $ fromIntegral <$> getFileSize resolved
          permissions <- liftIO $ getPermissions resolved
          pure [(rel, resolved, size, executable permissions)]

    resolve :: FilePath -> FilePath -> ExceptT Text IO FilePath
    resolve rel absPath = do
      isLink <- liftIO $ pathIsSymbolicLink absPath
      if isLink
        then do
          -- doesPathExist follows symlinks, so a False here means dangling.
          exists <- liftIO $ doesPathExist absPath
          unless exists $ throwError $ "dangling symlink: " <> cs rel
          liftIO $ canonicalizePath absPath
        else pure absPath

-- | A deterministic zip of walked output entries: fixed (epoch) timestamps
-- and unix modes 0755\/0644 depending on the executable bit, so the same
-- content always zips to the same bytes and exec bits survive extraction.
buildArtifactZip :: [(FilePath, FilePath, Int64, Bool)] -> IO Zip.Archive
buildArtifactZip = foldM addEntry Zip.emptyArchive
  where
    addEntry archive (rel, resolved, _size, exec) = do
      contents <- BS.readFile resolved
      let entry =
            (Zip.toEntry rel 0 (BSL.fromStrict contents))
              { -- "version made by" must declare unix (high byte 3) for
                -- extractors to honor the external attributes' mode bits.
                Zip.eVersionMadeBy = 3 `shiftL` 8,
                Zip.eExternalFileAttributes = (if exec then 0o755 else 0o644) `shiftL` 16
              }
      pure $ Zip.addEntryToArchive entry archive
