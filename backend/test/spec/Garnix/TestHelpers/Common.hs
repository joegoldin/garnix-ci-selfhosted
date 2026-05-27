module Garnix.TestHelpers.Common where

import Cradle qualified
import Garnix.Prelude
import Garnix.Types

commitAll :: (MonadIO m) => FilePath -> m CommitHash
commitAll dir = liftIO $ do
  Cradle.run_
    $ Cradle.cmd "git"
    & Cradle.setWorkingDir dir
    & Cradle.addArgs ["add", "." :: String]
  Cradle.run_
    $ Cradle.cmd "git"
    & Cradle.setWorkingDir dir
    & Cradle.addArgs ["commit", "--allow-empty", "-m", "A commit message" :: String]
    & Cradle.silenceStdout
  Cradle.StdoutTrimmed commit <-
    Cradle.run
      $ Cradle.cmd "git"
      & Cradle.setWorkingDir dir
      & Cradle.addArgs ["log", "-n", "1", "--pretty=format:%H" :: String]
  pure $ CommitHash $ cs commit
