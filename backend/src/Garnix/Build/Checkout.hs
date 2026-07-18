module Garnix.Build.Checkout
  ( withCheckout,
    remoteWithConfig,
    Remote,
    runWithCheckout,
    withAuthorization,
    withBeforeAction,
    cleanRemote,
  )
where

import Control.Lens qualified as Lens
import Control.Lens.Regex.Text qualified as Regex
import Garnix.Build.Helpers qualified as Internal
import Garnix.FlakeInputAuthorization (checkAuthorization)
import Garnix.GiteaInterface (giteaGetRemote, requireGiteaConfig)
import Garnix.Monad
import Garnix.Monad.ForkT (safeSystemTempDirectory)
import Garnix.Monad.Metrics
import Garnix.Monad.SubProcess.Deprecated qualified as Deprecated
import Garnix.Prelude
import Garnix.Types as Types
import Garnix.YamlConfig (GarnixConfig, getConfig)

withCheckout :: CommitInfo -> M a -> M a
withCheckout commitInfo action = do
  remote <- getRemoteForForge commitInfo
  inRunsDirectory . Internal.withPrivateNixXdgCache $ do
    timingAs #gitCloneTime $ void $ Deprecated.runProc "git" ["clone", "--filter=tree:0", realRemoteUrl remote, "."] []
    void $ Deprecated.runProc "git" ["checkout", getCommitHash (effectiveForgeRef commitInfo)] []
    cleanRemote remote
    action
  where
    inRunsDirectory :: (HasCallStack) => M a -> M a
    inRunsDirectory action = do
      tmp <- safeSystemTempDirectory "garnix-runs"
      local (#workingDir .~ tmp) action

-- | Clone URL, dispatched by forge: GitHub uses the app-token @github.com@ URL,
-- Gitea a tokenized URL against the configured instance.
getRemoteForForge :: (HasCallStack) => CommitInfo -> M RemoteUrl
getRemoteForForge commitInfo =
  case commitInfo ^. repoInfo . forge of
    ForgeGithub -> getRemote commitInfo
    ForgeGitea -> do
      cfg <- requireGiteaConfig
      pure $ giteaGetRemote cfg (commitInfo ^. repoInfo . ghRepoOwner) (commitInfo ^. repoInfo . ghRepoName)

-- Done so the token never leaks
cleanRemote :: RemoteUrl -> M ()
cleanRemote remote = do
  let cleanRemote = realRemoteUrl remote & [Regex.regex|x-access-token:.*@|] . Regex.match .~ ""
  void $ Deprecated.runProc "git" ["remote", "set-url", "origin", cleanRemote] []

newtype Remote = Remote
  { runWithCheckout :: forall a. CommitInfo -> (GarnixConfig -> M a) -> M a
  }

withBeforeAction :: M () -> Remote -> Remote
withBeforeAction before remote = Remote $ \commitInfo action -> do
  runWithCheckout remote commitInfo $ \garnixConfig -> do
    before
    action garnixConfig

remoteWithConfig :: (HasCallStack) => Remote
remoteWithConfig = Remote $ \commitInfo action -> do
  withCheckout commitInfo $ do
    config <- getConfig
    action config

withAuthorization :: FlakeDir -> RepoConfig -> CommitInfo -> M a -> M a
withAuthorization flakeDir repoConfig commitInfo action = do
  authConfig <- checkAuthorization flakeDir repoConfig commitInfo
  Lens.locally #userNixConfig (authConfig <>) action
