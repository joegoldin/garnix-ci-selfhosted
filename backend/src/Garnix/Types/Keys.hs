{-# LANGUAGE TemplateHaskell #-}

module Garnix.Types.Keys
  ( PublicKey (..),
    _PublicKey,
    PrivateKey,
    makePrivateKey,
    ExportKeysOpts (..),
    InstallPublicKeyOpts (..),
    RepoSecretsEncryptionKeyPath (..),
    RepoSecretsEncryptionPubKey (..),
    unsafeDecryptPrivateKey,
    exportKeys,
    exportKeysSshArgs,
    installPublicKey,
    installPublicKeySshArgs,
    deriveSshPublicKey,
  )
where

import Data.ByteString qualified as SBS
import Data.Text qualified as T
import Development.Shake qualified as Shake
import Garnix.Prelude
import Servant qualified
import System.Exit
import System.Process qualified as Proc

newtype PublicKey = PublicKey {getPublicKey :: Text}
  deriving stock (Eq, Show)
  deriving newtype
    ( Servant.MimeRender Servant.PlainText,
      PGColumn "character varying",
      PGColumn "text",
      PGParameter "character varying",
      PGParameter "text"
    )

-- * Private keys

-- Don't export the constructor or allow deserialization (besides DB).
-- That way only in this module can there be dangerous uses.
newtype PrivateKey = PrivateKey SBS.ByteString
  deriving newtype
    ( PGColumn "bytea",
      PGParameter "bytea"
    )

newtype RepoSecretsEncryptionKeyPath = RepoSecretsEncryptionKeyPath FilePath

newtype RepoSecretsEncryptionPubKey = RepoSecretsEncryptionPubKey Text

makePrivateKey :: Text -> RepoSecretsEncryptionPubKey -> IO (Either Text PrivateKey)
makePrivateKey unencrypted (RepoSecretsEncryptionPubKey i) = do
  result <-
    Shake.cmd
      ("age" :: String)
      ["--recipient" :: String, cs i]
      (Shake.Stdin $ cs unencrypted)
  case result of
    (Shake.Exit ExitSuccess, Shake.Stdout (stdout :: SBS.ByteString)) -> pure . Right . PrivateKey $ stdout
    _ -> pure $ Left "Encrypting keys failed"

unsafeDecryptPrivateKey :: PrivateKey -> RepoSecretsEncryptionKeyPath -> IO (Either Text Text)
unsafeDecryptPrivateKey (PrivateKey key) (RepoSecretsEncryptionKeyPath i) = do
  result <-
    Shake.cmd
      ("age" :: String)
      ["--decrypt" :: String, "-i", i]
      (Shake.StdinBS $ SBS.fromStrict key)
  case result of
    (Shake.Exit ExitSuccess, Shake.Stdout (stdout :: String)) -> pure . Right $ cs stdout
    _ -> pure $ Left "Decrypting keys failed"

data ExportKeysOpts = ExportKeysOpts
  { privateKey :: PrivateKey,
    ipAddr :: Text,
    targetPath :: FilePath,
    sshArgs :: [Text],
    sshUser :: Text,
    sshSudo :: Bool
  }

data InstallPublicKeyOpts = InstallPublicKeyOpts
  { installPublicKeyContents :: Text,
    installIpAddr :: Text,
    installTargetPath :: FilePath,
    installSshArgs :: [Text],
    installSshUser :: Text,
    installSshSudo :: Bool
  }

exportKeys :: ExportKeysOpts -> RepoSecretsEncryptionKeyPath -> IO (Either Text ())
exportKeys opts id = do
  eprivKey <- unsafeDecryptPrivateKey (privateKey opts) id
  case eprivKey of
    Left e -> return $ Left e
    Right privKey -> do
      -- Use stdin so we don't have to store the key in the filesystem. We don't
      -- capture or log stderr in case they contain the key.
      (exitCode, _, _) <-
        Proc.readProcessWithExitCode
          "ssh"
          (exportKeysSshArgs opts)
          (cs privKey)
      case exitCode of
        ExitSuccess -> pure $ Right ()
        ExitFailure _ -> pure $ Left "Exporting keys failed"

-- | Fixed ssh argv for streaming a decrypted repo key to a guest. Exported so
-- specs can pin the privilege boundary: first provisioning writes as root,
-- while persistent redeploys use the guest's established garnix + sudo path.
exportKeysSshArgs :: ExportKeysOpts -> [String]
exportKeysSshArgs opts =
  (cs <$> sshArgs opts)
    <> [cs (sshUser opts) <> "@" <> cs (ipAddr opts)]
    <> (if sshSudo opts then ["sudo", "-n"] else [])
    <> ["tee", targetPath opts, ">/dev/null"]

installPublicKey :: InstallPublicKeyOpts -> IO (Either Text ())
installPublicKey opts = do
  -- Stream only the public key and discard command output so neither the SSH
  -- transport nor an unexpected remote error can add key material to logs.
  (exitCode, _, _) <-
    Proc.readProcessWithExitCode
      "ssh"
      (installPublicKeySshArgs opts)
      (cs (installPublicKeyContents opts <> "\n"))
  case exitCode of
    ExitSuccess -> pure $ Right ()
    ExitFailure _ -> pure $ Left "Installing public key failed"

installPublicKeySshArgs :: InstallPublicKeyOpts -> [String]
installPublicKeySshArgs opts =
  (cs <$> installSshArgs opts)
    <> [cs (installSshUser opts) <> "@" <> cs (installIpAddr opts)]
    <> (if installSshSudo opts then ["sudo", "-n"] else [])
    <> ["install", "-D", "-m", "0644", "/dev/stdin", installTargetPath opts]

deriveSshPublicKey :: FilePath -> IO (Either Text Text)
deriveSshPublicKey privateKeyPath = do
  (exitCode, stdout, _) <-
    Proc.readProcessWithExitCode
      "ssh-keygen"
      ["-y", "-f", privateKeyPath]
      ""
  let publicKey = T.strip (cs stdout)
  case exitCode of
    ExitSuccess | not (T.null publicKey) -> pure $ Right publicKey
    _ -> pure $ Left "Deriving SSH public key failed"

makePrisms ''PublicKey
