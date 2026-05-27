module Garnix.Monad.SubProcess.Deprecated (runProc) where

import Control.Exception (ErrorCall (ErrorCall), throwIO)
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import System.Environment (getEnvironment)
import System.Process qualified as Proc
import System.Process.Typed

runProc ::
  (HasCallStack) =>
  Text ->
  [Text] ->
  [(Text, Text)] ->
  M Text
runProc cmd args addedEnv = do
  dir <- view #workingDir
  go dir
    <?> ( "Running command"
            <> cs (show (cmd, args))
            <> " in dir "
            <> cs dir
        )
  where
    go dir = do
      environment <- liftIO $ addToParentEnv addedEnv
      (exitCode', out, err) <-
        -- See [Async process exceptions]
        liftIO
          $ Proc.readCreateProcessWithExitCode
            ( ( Proc.proc
                  (cs cmd)
                  (cs <$> args)
              )
                { Proc.cwd = Just dir,
                  Proc.std_in = Proc.NoStream,
                  Proc.std_out = Proc.CreatePipe,
                  Proc.std_err = Proc.CreatePipe,
                  Proc.env = Just environment
                }
            )
            ""
      case exitCode' of
        ExitSuccess -> pure $ cs out
        ExitFailure no -> do
          let error = RunProcessError cmd args (cs err) (cs out) no
          log Warning $ "Command " <> cs (show (cmd, args)) <> " failed with " <> show error
          throw error

addToParentEnv :: [(Text, Text)] -> IO [(String, String)]
addToParentEnv addedEnv = do
  parentEnv <- getEnvironment
  let parentKeys :: [Text] = map (cs . fst) parentEnv
  forM_ addedEnv $ \(added, _) -> do
    when (added `elem` parentKeys) $ do
      throwIO $ ErrorCall $ cs $ "runProcIOEnv: overwriting environment variable: " <> added
  pure $ map (bimap cs cs) addedEnv ++ parentEnv
