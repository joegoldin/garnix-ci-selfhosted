module Garnix.ArtifactsSpec (spec) where

import Codec.Archive.Zip qualified as Zip
import Cradle
import Crypto.Hash (SHA256 (..), hashWith)
import Data.Aeson qualified as Aeson
import Data.Bits (shiftL)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map (Map)
import Data.Map qualified as Map
import Garnix.Artifacts
import Garnix.DB.Artifacts qualified as DB
import Garnix.Monad
import Garnix.Nix.Types qualified as Nix
import Garnix.Prelude
import Garnix.TestHelpers (testBuild, truncateDBM)
import Garnix.TestHelpers.Monad (aroundM_, beforeM_, inM, shouldBeM, shouldReturnM, suppressLogsWhenPassing)
import Garnix.Types
import Garnix.YamlConfig (ArtifactSection (..), GarnixConfig, artifacts)
import System.Directory (canonicalizePath, createDirectoryIfMissing, createFileLink, getFileSize, getPermissions, setOwnerExecutable, setPermissions)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "walkOutput" $ do
    it "walks files, dereferences symlinks, and records exec bits" $ do
      withSystemTempDirectory "artifact" $ \dir -> do
        writeFile (dir </> "a.txt") "hello"
        createDirectoryIfMissing True (dir </> "sub")
        writeFile (dir </> "sub" </> "b.sh") "#!/bin/sh"
        permissions <- getPermissions (dir </> "sub" </> "b.sh")
        setPermissions (dir </> "sub" </> "b.sh") (setOwnerExecutable True permissions)
        createFileLink (dir </> "a.txt") (dir </> "link.txt")
        result <- walkOutput dir
        case result of
          Left err -> expectationFailure $ cs err
          Right entries -> do
            map (\(rel, _, _, _) -> rel) entries `shouldBe` ["a.txt", "link.txt", "sub/b.sh"]
            map (\(_, _, size, _) -> size) entries `shouldBe` [5, 5, 9]
            map (\(_, _, _, exec) -> exec) entries `shouldBe` [False, False, True]
            canonicalA <- canonicalizePath (dir </> "a.txt")
            map (\(rel, resolved, _, _) -> (rel, resolved)) entries
              `shouldContain` [("link.txt", canonicalA)]

    it "fails on dangling symlinks" $ do
      withSystemTempDirectory "artifact" $ \dir -> do
        createFileLink (dir </> "missing") (dir </> "dangling")
        result <- walkOutput dir
        result `shouldSatisfy` isLeft

    it "fails when the root is not a directory" $ do
      withSystemTempDirectory "artifact" $ \dir -> do
        writeFile (dir </> "file") "x"
        result <- walkOutput (dir </> "file")
        result `shouldSatisfy` isLeft

  describe "ArtifactManifest" $ do
    it "serializes to snake_case JSON" $ do
      let manifest =
            ArtifactManifest
              { _artifactManifestFiles =
                  [ ManifestFile
                      { _manifestFilePath = "sub/b.sh",
                        _manifestFileSize = 9,
                        _manifestFileSha256 = "abc123",
                        _manifestFileExecutable = True
                      }
                  ],
                _artifactManifestTotalSize = 9,
                _artifactManifestFileCount = 1,
                _artifactManifestStoreHash = "somehash"
              }
      toJSON manifest
        `shouldBe` [aesonQQ|{
          "files": [{"path": "sub/b.sh", "size": 9, "sha256": "abc123", "executable": true}],
          "total_size": 9,
          "file_count": 1,
          "store_hash": "somehash"
        }|]
      Aeson.decode (Aeson.encode manifest) `shouldBe` Just (toJSON manifest)

  describe "buildArtifactZip" $ do
    it "builds a deterministic zip with unix modes and epoch timestamps" $ do
      withSystemTempDirectory "artifact" $ \dir -> do
        writeFile (dir </> "a.txt") "hello"
        writeFile (dir </> "b.sh") "#!/bin/sh"
        let entries =
              [ ("a.txt", dir </> "a.txt", 5, False),
                ("sub/b.sh", dir </> "b.sh", 9, True)
              ]
        archive <- buildArtifactZip entries
        sort (Zip.filesInArchive archive) `shouldBe` ["a.txt", "sub/b.sh"]
        (Zip.fromEntry <$> Zip.findEntryByPath "a.txt" archive) `shouldBe` Just "hello"
        (Zip.eLastModified <$> Zip.findEntryByPath "a.txt" archive) `shouldBe` Just 0
        (Zip.eExternalFileAttributes <$> Zip.findEntryByPath "a.txt" archive)
          `shouldBe` Just (0o644 `shiftL` 16)
        (Zip.eExternalFileAttributes <$> Zip.findEntryByPath "sub/b.sh" archive)
          `shouldBe` Just (0o755 `shiftL` 16)
        again <- buildArtifactZip entries
        Zip.fromArchive again `shouldBe` Zip.fromArchive archive

  describe "publish pipeline" $ inM $ aroundM_ suppressLogsWhenPassing $ beforeM_ truncateDBM $ do
    describe "publishOutput" $ do
      it "uploads files, all.zip, and manifest.json, and records the artifact" $ do
        withSystemTempDirectory "artifact" $ \dir -> do
          liftIO $ do
            writeFile (dir </> "a.txt") "hello"
            createDirectoryIfMissing True (dir </> "sub")
            writeFile (dir </> "sub" </> "b.sh") "#!/bin/sh"
            permissions <- getPermissions (dir </> "sub" </> "b.sh")
            setPermissions (dir </> "sub" </> "b.sh") (setOwnerExecutable True permissions)
            createFileLink "a.txt" (dir </> "link.txt")
          build <- testBuild (package .~ "artifact-pkg")
          withFakeStore $ \store uploadsRef bytesRef -> do
            publishOutput store build "claude-skills" "fakehash123" dir
            uploads <- liftIO $ readIORef uploadsRef
            Map.keys uploads
              `shouldBeM` [ ("public", "artifacts/fakehash123/all.zip"),
                            ("public", "artifacts/fakehash123/files/a.txt"),
                            ("public", "artifacts/fakehash123/files/link.txt"),
                            ("public", "artifacts/fakehash123/files/sub/b.sh"),
                            ("public", "artifacts/fakehash123/manifest.json")
                          ]
            manifest :: Maybe Aeson.Value <-
              liftIO $ (Aeson.decode <=< Map.lookup "artifacts/fakehash123/manifest.json") <$> readIORef bytesRef
            let shaHello = sha256Hex "hello"
                shaScript = sha256Hex "#!/bin/sh"
            manifest
              `shouldBeM` Just
                [aesonQQ|{
                  "files": [
                    {"path": "a.txt", "size": 5, "sha256": #{shaHello}, "executable": false},
                    {"path": "link.txt", "size": 5, "sha256": #{shaHello}, "executable": false},
                    {"path": "sub/b.sh", "size": 9, "sha256": #{shaScript}, "executable": true}
                  ],
                  "total_size": 19,
                  "file_count": 3,
                  "store_hash": "fakehash123"
                }|]
            rows <- DB.getArtifactsForBuild (build ^. id)
            map DB._artifactRowName rows `shouldBeM` ["claude-skills"]
            map DB._artifactRowStatus rows `shouldBeM` ["published"]
            map DB._artifactRowStoreHash rows `shouldBeM` ["fakehash123"]
            map DB._artifactRowBucket rows `shouldBeM` [ArtifactPublic]
            DB.artifactObjectExists "fakehash123" ArtifactPublic `shouldReturnM` True

      it "skips uploading when the object already exists, but still records the row" $ do
        withSystemTempDirectory "artifact" $ \dir -> do
          liftIO $ writeFile (dir </> "a.txt") "hello"
          build1 <- testBuild (package .~ "artifact-pkg")
          build2 <- testBuild (package .~ "artifact-pkg")
          withFakeStore $ \store uploadsRef _bytesRef -> do
            publishOutput store build1 "claude-skills" "fakehash123" dir
            firstUploads <- liftIO $ readIORef uploadsRef
            liftIO $ Map.size firstUploads `shouldBe` 3
            publishOutput store build2 "claude-skills" "fakehash123" dir
            liftIO (readIORef uploadsRef) `shouldReturnM` firstUploads
            rows <- DB.getArtifactsForBuild (build2 ^. id)
            map DB._artifactRowStatus rows `shouldBeM` ["published"]

      it "publishes private repos to the private bucket" $ do
        withSystemTempDirectory "artifact" $ \dir -> do
          liftIO $ writeFile (dir </> "a.txt") "hello"
          build <- testBuild ((package .~ "artifact-pkg") . (repoIsPublic .~ RepoIsPublic False))
          withFakeStore $ \store uploadsRef _bytesRef -> do
            publishOutput store build "claude-skills" "privhash" dir
            uploads <- liftIO $ readIORef uploadsRef
            liftIO $ map fst (Map.keys uploads) `shouldSatisfy` all (== "private")
            rows <- DB.getArtifactsForBuild (build ^. id)
            map DB._artifactRowBucket rows `shouldBeM` [ArtifactPrivate]

      it "throws on dangling symlinks and uploads nothing" $ do
        withSystemTempDirectory "artifact" $ \dir -> do
          liftIO $ createFileLink "missing" (dir </> "dangling")
          build <- testBuild (package .~ "artifact-pkg")
          withFakeStore $ \store uploadsRef _bytesRef -> do
            result <- tryEither $ publishOutput store build "claude-skills" "danglinghash" dir
            liftIO $ result `shouldSatisfy` isLeft
            liftIO (readIORef uploadsRef) `shouldReturnM` Map.empty
            DB.getArtifactsForBuild (build ^. id) `shouldReturnM` []

    describe "publishArtifacts" $ do
      it "is a no-op when no artifact store is configured" $ do
        build <- testBuild (package .~ "artifact-pkg")
        -- the test Env has artifactStore = Nothing by default
        publishArtifacts artifactConfig [build]
        DB.getArtifactsForBuild (build ^. id) `shouldReturnM` []

      it "only publishes successful package builds of the configured packages" $ do
        otherPackage <- testBuild (package .~ "other-pkg")
        unsuccessful <- testBuild ((package .~ "artifact-pkg") . (status .~ Just Failure))
        app <- testBuild ((package .~ "artifact-pkg") . (packageType .~ TypeApp))
        withFakeStore $ \_store uploadsRef _bytesRef -> do
          publishArtifacts artifactConfig [otherPackage, unsuccessful, app]
          liftIO (readIORef uploadsRef) `shouldReturnM` Map.empty
          forM_ [otherPackage, unsuccessful, app] $ \build ->
            DB.getArtifactsForBuild (build ^. id) `shouldReturnM` []

      it "records a failed row when the build has no store path" $ do
        build <- testBuild (package .~ "artifact-pkg")
        withFakeStore $ \_store uploadsRef _bytesRef -> do
          publishArtifacts artifactConfig [build]
          rows <- DB.getArtifactsForBuild (build ^. id)
          map DB._artifactRowName rows `shouldBeM` ["claude-skills"]
          map DB._artifactRowStatus rows `shouldBeM` ["failed"]
          map DB._artifactRowStoreHash rows `shouldBeM` [""]
          liftIO (readIORef uploadsRef) `shouldReturnM` Map.empty

      it "records a failed row for invalid artifact names" $ do
        build <- testBuild (package .~ "artifact-pkg")
        let config = def & artifacts .~ [ArtifactSection "artifact-pkg" (Just "bad name!")]
        withFakeStore $ \_store uploadsRef _bytesRef -> do
          publishArtifacts config [build]
          rows <- DB.getArtifactsForBuild (build ^. id)
          map DB._artifactRowName rows `shouldBeM` ["bad name!"]
          map DB._artifactRowStatus rows `shouldBeM` ["failed"]
          liftIO (readIORef uploadsRef) `shouldReturnM` Map.empty

      it "publishes a build's real store path end-to-end" $ do
        withSystemTempDirectory "artifact" $ \dir -> do
          liftIO $ do
            writeFile (dir </> "a.txt") "hello"
            createDirectoryIfMissing True (dir </> "sub")
            writeFile (dir </> "sub" </> "b.sh") "#!/bin/sh"
            permissions <- getPermissions (dir </> "sub" </> "b.sh")
            setPermissions (dir </> "sub" </> "b.sh") (setOwnerExecutable True permissions)
          storePath <- registerStorePath dir
          let hash = cs (Nix.getHash storePath) :: Text
          build <- buildWithOutput storePath
          withFakeStore $ \_store uploadsRef _bytesRef -> do
            publishArtifacts artifactConfig [build]
            uploads <- liftIO $ readIORef uploadsRef
            Map.keys uploads
              `shouldBeM` [ ("public", "artifacts/" <> hash <> "/all.zip"),
                            ("public", "artifacts/" <> hash <> "/files/a.txt"),
                            ("public", "artifacts/" <> hash <> "/files/sub/b.sh"),
                            ("public", "artifacts/" <> hash <> "/manifest.json")
                          ]
            rows <- DB.getArtifactsForBuild (build ^. id)
            map DB._artifactRowName rows `shouldBeM` ["claude-skills"]
            map DB._artifactRowStatus rows `shouldBeM` ["published"]
            map DB._artifactRowStoreHash rows `shouldBeM` [hash]
            DB.artifactObjectExists hash ArtifactPublic `shouldReturnM` True

      it "records a failed row instead of throwing when the store path is broken" $ do
        withSystemTempDirectory "artifact" $ \dir -> do
          liftIO $ createFileLink "missing" (dir </> "dangling")
          storePath <- registerStorePath dir
          build <- buildWithOutput storePath
          withFakeStore $ \_store uploadsRef _bytesRef -> do
            publishArtifacts artifactConfig [build]
            rows <- DB.getArtifactsForBuild (build ^. id)
            map DB._artifactRowStatus rows `shouldBeM` ["failed"]
            map DB._artifactRowStoreHash rows `shouldBeM` [""]
            liftIO (readIORef uploadsRef) `shouldReturnM` Map.empty

artifactConfig :: GarnixConfig
artifactConfig = def & artifacts .~ [ArtifactSection "artifact-pkg" (Just "claude-skills")]

sha256Hex :: BS.ByteString -> Text
sha256Hex = show . hashWith SHA256

-- | An in-memory 'ArtifactStore': records uploaded keys (bucket text, key) →
-- size, and the raw bytes of 'putBytes' uploads, keyed by object key.
withFakeStore ::
  (ArtifactStore -> IORef (Map (Text, Text) Int64) -> IORef (Map Text BSL.ByteString) -> M a) ->
  M a
withFakeStore action = do
  uploadsRef <- liftIO $ newIORef Map.empty
  bytesRef <- liftIO $ newIORef Map.empty
  let record bucket key size = modifyIORef' uploadsRef (Map.insert (artifactBucketText bucket, key) size)
      store =
        ArtifactStore
          { _artifactStorePutFile = \bucket key path -> liftIO $ do
              size <- getFileSize path
              record bucket key (fromIntegral size),
            _artifactStorePutBytes = \bucket key bytes -> liftIO $ do
              record bucket key (fromIntegral (BSL.length bytes))
              modifyIORef' bytesRef (Map.insert key bytes),
            _artifactStoreDeletePrefix = \_ _ -> pure (),
            _artifactStorePresignGet = \_ key -> pure key,
            _artifactStorePublicUrl = identity
          }
  local (#artifactStore ?~ store) $ action store uploadsRef bytesRef

-- | Register a directory's contents as a real nix store path (so
-- 'Garnix.Nix.StorePath.withStorePath' can resolve and GC-root it).
registerStorePath :: FilePath -> M Nix.StorePath
registerStorePath dir = do
  StdoutTrimmed out <- run $ cmd "nix-store" & addArgs ["--add", cs dir :: Text]
  case Nix.parseStorePath out of
    Left err -> throw $ OtherError err
    Right storePath -> pure storePath

buildWithOutput :: Nix.StorePath -> M Build
buildWithOutput storePath =
  testBuild
    $ (package .~ "artifact-pkg")
    . (outputPaths ?~ BuildOutputsPgColumn (Nix.BuildOutputs (Map.fromList [("out", storePath)])))
