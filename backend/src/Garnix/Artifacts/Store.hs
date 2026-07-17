-- | The amazonka-backed production implementation of 'ArtifactStore'.
--
-- Objects live in one of two buckets ('ArtifactBucket'): the public bucket is
-- served directly via its public base URL, the private one via short-lived
-- presigned GET URLs. Each bucket has its own credential pair (B2 application
-- keys are single-bucket), mirroring how the binary cache's 'S3CacheEnv'
-- handles its public/private pair.
module Garnix.Artifacts.Store (s3ArtifactStore) where

import Amazonka qualified
import Amazonka.S3 qualified as Amazonka
import Data.ByteString.Lazy qualified as BSL
import Garnix.Duration
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types

-- | @s3ArtifactStore publicEnv privateEnv publicBucket privateBucket publicBaseUrl@
--
-- The two 'Amazonka.Env's carry the credentials for the public and private
-- bucket respectively; @publicBaseUrl@ is the base URL under which the public
-- bucket's objects are downloadable (no trailing slash needed).
s3ArtifactStore ::
  Amazonka.Env ->
  Amazonka.Env ->
  Amazonka.BucketName ->
  Amazonka.BucketName ->
  Text ->
  ArtifactStore
s3ArtifactStore publicEnv privateEnv publicBucket privateBucket publicBaseUrl =
  ArtifactStore
    { _artifactStorePutFile = putFile,
      _artifactStorePutBytes = putBytes,
      _artifactStoreDeletePrefix = deletePrefix,
      _artifactStorePresignGet = presignGet,
      _artifactStorePublicUrl = publicUrl
    }
  where
    envFor :: ArtifactBucket -> Amazonka.Env
    envFor = \case
      ArtifactPublic -> publicEnv
      ArtifactPrivate -> privateEnv

    bucketFor :: ArtifactBucket -> Amazonka.BucketName
    bucketFor = \case
      ArtifactPublic -> publicBucket
      ArtifactPrivate -> privateBucket

    putFile :: ArtifactBucket -> Text -> FilePath -> M ()
    putFile artifactBucket key path = do
      body <- Amazonka.toBody <$> Amazonka.hashedFile path
      void
        $ send (envFor artifactBucket)
        $ Amazonka.newPutObject (bucketFor artifactBucket) (Amazonka.ObjectKey key) body

    putBytes :: ArtifactBucket -> Text -> BSL.ByteString -> M ()
    putBytes artifactBucket key bytes =
      void
        $ send (envFor artifactBucket)
        $ Amazonka.newPutObject
          (bucketFor artifactBucket)
          (Amazonka.ObjectKey key)
          (Amazonka.toBody bytes)

    deletePrefix :: ArtifactBucket -> Text -> M ()
    deletePrefix artifactBucket prefix = loop Nothing
      where
        env = envFor artifactBucket
        bucket = bucketFor artifactBucket
        loop :: Maybe Text -> M ()
        loop continuationToken = do
          response <-
            send env
              $ Amazonka.newListObjectsV2 bucket
              & (#prefix ?~ prefix)
              & (#continuationToken .~ continuationToken)
          forM_ (fromMaybe [] (response ^. #contents)) $ \object ->
            void $ send env $ Amazonka.newDeleteObject bucket (object ^. #key)
          case (response ^. #isTruncated, response ^. #nextContinuationToken) of
            (Just True, Just token) -> loop (Just token)
            _ -> pure ()

    presignGet :: ArtifactBucket -> Text -> M Text
    presignGet artifactBucket key = do
      now <- liftIO getCurrentTime
      cs
        <$> Amazonka.presignURL
          (envFor artifactBucket)
          now
          (toAmazonkaSeconds (fromMinutes @Int 10))
          (Amazonka.newGetObject (bucketFor artifactBucket) (Amazonka.ObjectKey key))

    publicUrl :: Text -> Text
    publicUrl key = publicBaseUrl <> "/" <> key

toAmazonkaSeconds :: Duration -> Amazonka.Seconds
toAmazonkaSeconds = Amazonka.Seconds . realToFrac . toSeconds

send ::
  (Amazonka.AWSRequest request, Typeable request, Typeable (Amazonka.AWSResponse request)) =>
  Amazonka.Env ->
  request ->
  M (Amazonka.AWSResponse request)
send env request = do
  response <-
    liftIO
      $ runResourceT
      $ Amazonka.sendEither env request
  case response of
    Left error -> throw $ OtherError $ show error
    Right response -> pure response
