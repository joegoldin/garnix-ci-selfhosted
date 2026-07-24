-- | The amazonka-backed production implementation of 'BackupStore'.
--
-- One private bucket with its own single-bucket credential pair (B2
-- application keys are single-bucket). Downloads are served via short-lived
-- presigned GET URLs only — server backups are always sensitive, so unlike
-- artifacts there is no public bucket and no stable public URL.
module Garnix.Backups.Store (s3BackupStore) where

import Amazonka qualified
import Amazonka.S3 qualified as Amazonka
import Conduit (sinkFile)
import Garnix.Duration
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types

s3BackupStore :: Amazonka.Env -> Amazonka.BucketName -> Integer -> BackupStore
s3BackupStore env bucket maxSize =
  BackupStore
    { _backupStorePutFile = putFile,
      _backupStoreGetFile = getFile,
      _backupStoreDeleteObject = deleteObject,
      _backupStorePresignGet = presignGet,
      _backupStoreMaxSize = maxSize
    }
  where
    putFile :: Text -> FilePath -> M ()
    putFile key path = do
      body <- Amazonka.toBody <$> Amazonka.hashedFile path
      void
        $ send env
        $ Amazonka.newPutObject bucket (Amazonka.ObjectKey key) body

    getFile :: Text -> FilePath -> M ()
    getFile key path = do
      response <-
        liftIO
          $ runResourceT
          $ Amazonka.sendEither env (Amazonka.newGetObject bucket (Amazonka.ObjectKey key))
      case response of
        Left err -> throw $ OtherError $ show err
        Right ok ->
          liftIO
            $ runResourceT
            $ Amazonka.sinkBody (ok ^. #body) (sinkFile path)

    deleteObject :: Text -> M ()
    deleteObject key =
      void
        $ send env
        $ Amazonka.newDeleteObject bucket (Amazonka.ObjectKey key)

    presignGet :: Text -> M Text
    presignGet key = do
      now <- liftIO getCurrentTime
      cs
        <$> Amazonka.presignURL
          env
          now
          (toAmazonkaSeconds (fromMinutes @Int 10))
          (Amazonka.newGetObject bucket (Amazonka.ObjectKey key))

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
