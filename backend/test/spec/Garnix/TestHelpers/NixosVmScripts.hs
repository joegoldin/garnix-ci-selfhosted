module Garnix.TestHelpers.NixosVmScripts (getActionRunnerVmScript) where

import Control.Concurrent.Lifted
import Control.Exception.Safe qualified
import Cradle qualified
import Garnix.NixConfig (nixConfDefaults)
import Garnix.Prelude
import System.Directory (doesPathExist)
import System.IO.Unsafe qualified

getActionRunnerVmScript :: IO FilePath
getActionRunnerVmScript = do
  r <- modifyMVar __actionRunnerCache $ \case
    Nothing -> do
      result <- Control.Exception.Safe.try uncachedGetActionRunnerScript
      pure (Just result, result)
    Just r -> pure (Just r, r)
  case r of
    Right script -> pure script
    Left e -> Control.Exception.Safe.throwIO e

{-# NOINLINE __actionRunnerCache #-}
__actionRunnerCache :: MVar (Maybe (Either SomeException FilePath))
__actionRunnerCache = System.IO.Unsafe.unsafePerformIO $ newMVar Nothing

uncachedGetActionRunnerScript :: IO FilePath
uncachedGetActionRunnerScript = do
  -- Local test runs sit in a real checkout, where git+file filters ignored
  -- runtime state such as pg-tmp sockets. The packaged backend_specs action
  -- copies the flake source (without .git) into a temporary directory, where
  -- the same reference must be an explicit path flake instead.
  hasGitMetadata <- doesPathExist "../.git"
  let sourceRef = if hasGitMetadata then "git+file:.." else "path:.."
  (exitCode, Cradle.StdoutTrimmed vmPath, Cradle.StderrRaw err) <-
    Cradle.run
      $ Cradle.cmd "nix"
      & Cradle.addArgs @Text
        [ "build",
          "-L",
          -- The spec runner starts in backend/, one directory below the copied
          -- path flake. Avoid a bare .# reference: an unrelated parent Git
          -- repository can otherwise capture it on Nix 2.34.
          sourceRef <> "#nixosConfigurations.action-runner2.config.system.build.vm",
          "--print-out-paths",
          "--no-link"
        ]
      & nixConfDefaults
      & Cradle.silenceStderr
  when (exitCode /= Cradle.ExitSuccess) $ do
    error $ "Failed building the action runner vm. Stderr:\n" <> cs err
  pure $ cs vmPath </> "bin/run-action-runner2-vm"
