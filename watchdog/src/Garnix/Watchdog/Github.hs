module Garnix.Watchdog.Github where

import Control.Monad
import Cradle
import Data.String.Conversions
import Data.Text as T
import Garnix.Watchdog.Utils
import System.Exit (exitWith)
import System.IO.Temp
import Prelude hiding (log)

testRepoUrl :: Text
testRepoUrl = "git@github.com:garnix-watchdog/watchdog-test-repo.git"

data Repo = Repo
  { repoDir :: FilePath,
    sshIdentityFile :: FilePath
  }

withTestRepo :: CheckName -> FilePath -> (Repo -> IO a) -> IO a
withTestRepo check sshIdentityFile action = withSystemTempDirectory "watchdog" $ \repoDir -> do
  let repo = Repo {repoDir, sshIdentityFile}
  git check repo ["clone", testRepoUrl, "."]
  action repo

pushTestRepo :: CheckName -> Repo -> Text -> Text -> IO ()
pushTestRepo check repo commitMessage branch = do
  git check repo ["add", "."]
  git check repo ["commit", "--message", commitMessage]
  git check repo ["push", "origin", "HEAD:refs/heads/" <> branch, "--force"]

git :: CheckName -> Repo -> [Text] -> IO ()
git check Repo {repoDir, sshIdentityFile} args = do
  (StdoutRaw stdout, StderrRaw stderr, exitCode) <-
    run $
      cmd "git"
        & setWorkingDir repoDir
        & modifyEnvVar "GIT_AUTHOR_NAME" (const $ pure "garnix watchdog")
        & modifyEnvVar "GIT_AUTHOR_EMAIL" (const $ pure "dev@garnix.io")
        & modifyEnvVar "GIT_COMMITTER_NAME" (const $ pure "garnix watchdog")
        & modifyEnvVar "GIT_COMMITTER_EMAIL" (const $ pure "dev@garnix.io")
        & addArgs args
        & modifyEnvVar "GIT_SSH_COMMAND" (const $ Just $ "ssh -i " <> sshIdentityFile <> " -o IdentitiesOnly=yes")
  when (exitCode /= ExitSuccess) $ do
    log check $ cs stdout
    log check $ cs stderr
    log check $ "command failed: git " <> T.unwords args
    exitWith exitCode
