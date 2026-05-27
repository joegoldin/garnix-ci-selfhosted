module Garnix.Monad.SubProcess
  ( withUtf8LinesStream,
    runGitProcess,
    runSubProcess,
    runSubProcess_,
  )
where

import Control.Concurrent.Async.Lifted (wait, withAsync)
import Control.Exception (throwIO)
import Control.Monad.Trans.Control
import Cradle qualified
import Cradle.ProcessConfiguration qualified as Cradle
import Foreign.C.Error (Errno (..), ePIPE)
import GHC.IO.Exception (IOErrorType (ResourceVanished), IOException (IOError), ioe_errno, ioe_type)
import Garnix.Monad
import Garnix.Prelude
import Garnix.SafeUnix (safeCreatePipe)
import Garnix.Types
import Streaming.Prelude qualified as S
import System.IO (hClose, hSetEncoding, utf8)

-- * streaming helpers

withUtf8LinesStream ::
  forall m a.
  (MonadBaseControl IO m, MonadMask m, MonadIO m) =>
  (String -> m ()) ->
  (Handle -> m a) ->
  m a
withUtf8LinesStream consumer action = do
  bracket
    ( liftIO $ do
        (a, b) <- safeCreatePipe
        hSetBuffering a LineBuffering
        hSetBuffering b LineBuffering
        hSetEncoding a utf8
        hSetEncoding b utf8
        return (a, b)
    )
    -- This cleanup logic follows https://hackage.haskell.org/package/process-1.6.18.0/docs/src/System.Process.html#cleanupProcess
    ( \(readEnd, writeEnd) -> liftIO $ do
        ignoreSigPipe $ hClose writeEnd
        hClose readEnd
    )
    ( \(readEnd, writeEnd) -> do
        withAsync (S.mapM_ consumer (S.fromHandle readEnd)) $ \streamWriter -> do
          output <- action writeEnd
          liftIO $ hClose writeEnd
          wait streamWriter :: m ()
          pure output
    )
  where
    ignoreSigPipe :: IO () -> IO ()
    ignoreSigPipe = handle $ \e -> case e of
      IOError
        { ioe_type = ResourceVanished,
          ioe_errno = Just ioe
        }
          | Errno ioe == ePIPE -> return ()
      _ -> throwIO e

runGitProcess :: [Text] -> M ()
runGitProcess args = do
  dir <- view #workingDir
  result <-
    Cradle.run
      $ Cradle.cmd "git"
      & Cradle.modifyEnvVar "GIT_AUTHOR_NAME" (const $ pure "garnix-bot")
      & Cradle.modifyEnvVar "GIT_AUTHOR_EMAIL" (const $ pure "contact@garnix.io")
      & Cradle.modifyEnvVar "GIT_COMMITTER_NAME" (const $ pure "garnix-bot")
      & Cradle.modifyEnvVar "GIT_COMMITTER_EMAIL" (const $ pure "contact@garnix.io")
      & Cradle.addArgs args
      & Cradle.setWorkingDir dir
  case result of
    (Cradle.ExitFailure code, Cradle.StdoutRaw out, Cradle.StderrRaw err) -> do
      log Warning
        $ "SubProcess.runGitProcess error: '"
        <> show args
        <> "': stdout ("
        <> cs out
        <> ") stderr ("
        <> cs err
        <> ")"
      throw RunProcessError {command = "git", arguments = args, stdErr = cs err, stdOut = cs out, exitCode = code}
    (Cradle.ExitSuccess, _, _) ->
      log Informational $ "SubProcess.runGitProcess: successfully ran git command: " <> show args

runSubProcess :: (Cradle.Output o) => Cradle.ProcessConfiguration -> M o
runSubProcess config = do
  (output, exitCode, Cradle.StdoutRaw stdout, Cradle.StderrRaw stderr) <-
    Cradle.run config
  case exitCode of
    Cradle.ExitFailure exitCode -> do
      spans <- view #spanCtx
      let e =
            ErrorWithContext
              { callstack = callStack,
                spans,
                severity = Error,
                err =
                  RunProcessError
                    { command = cs $ Cradle.executable config,
                      arguments = map cs $ Cradle.arguments config,
                      stdOut = cs stdout,
                      stdErr = cs stderr,
                      exitCode
                    }
              }
      log Warning $ "Command " <> cs (Cradle.executable config) <> " failed with " <> show e
      throwError e
    Cradle.ExitSuccess -> pure output

runSubProcess_ :: Cradle.ProcessConfiguration -> M ()
runSubProcess_ = runSubProcess
