{-# LANGUAGE DuplicateRecordFields #-}

module Garnix.Orchestrator
  ( handlePullRequest,
    handleCommit,
    handleRerun,
    restartBuild,
    restartCommit,
    listRepoBranches,
    triggerBranchBuild,
    RerunEvent (..),
  )
where

import Garnix.Async (Promise)
import Garnix.Build (buildFlake, rerunBuild)
import Garnix.Build.Checkout qualified as Build.Checkout
import Garnix.Build.Helpers (withInternalCacheToken)
import Garnix.DB qualified as DB
import Garnix.GiteaInterface (requireGiteaConfig)
import Garnix.GithubInterface (listBranchesGithub)
import Garnix.Hosting.Deploy (rolloutNewServerVersion)
import Garnix.Monad
import Garnix.Monad.Async (emptyPromise, resolve, spawn)
import Garnix.Prelude
import Garnix.Reporters.GiteaReporter (mkGiteaReporter)
import Garnix.Reporters.GithubReporter (mkGithubReporter)
import Garnix.Reporters.OpenSearchReporter (openSearchReporter)
import Garnix.Types hiding (ghRunId)
import Garnix.Types qualified as Types
import GitHub.App.Auth qualified as GH
import GitHub.Data.Id (Id (Id))

data RerunEvent = RerunEvent
  { reqUser :: GhLogin,
    ghRunId :: GhRunId,
    installAuth :: GH.InstallationAuth,
    token :: GhToken,
    repoIsPublic :: RepoPublicity
  }
  deriving stock (Generic)

handlePullRequest :: (HasCallStack) => Reporter -> CommitInfo -> GhPullRequestId -> M (Promise ())
handlePullRequest reporter commitInfo prId = do
  assertIsAllowedToBuild (commitInfo ^. repoInfo . ghRepoOwner) (commitInfo ^. repoInfo . ghRepoName)

  withSpan commitInfo $ spawn $ do
    -- We assume the build is already running if it's NOT a fork.
    when (isJust $ commitInfo ^. prFromFork) $ do
      buildFlake reporter commitInfo >>= resolve

    -- If it's not a fork, we're already attempting to deploy in `buildFlake`.
    when (isNothing $ commitInfo ^. prFromFork) $ do
      deployPrServers prId
  where
    deployPrServers :: GhPullRequestId -> M ()
    deployPrServers prId = do
      Build.Checkout.withCheckout commitInfo $ withSpan prId $ do
        withInternalCacheToken (commitInfo ^. Types.reqUser) $ do
          void (rolloutNewServerVersion reporter commitInfo $ GhPrDeployment prId)

handleCommit :: (HasCallStack) => Reporter -> Bool -> CommitInfo -> M (Promise ())
handleCommit reporter allowDuplicateRun commitInfo = do
  withSpan commitInfo $ do
    assertIsAllowedToBuild (commitInfo ^. repoInfo . ghRepoOwner) (commitInfo ^. repoInfo . ghRepoName)
    pushResult <- case commitInfo ^. branch of
      Nothing -> do
        log Informational "handleCommit: CommitInfo is missing branch. Not registering push"
        pure Nothing
      Just branch -> do
        Just
          <$> DB.registerPush
            (commitInfo ^. repoInfo . ghRepoOwner)
            (commitInfo ^. repoInfo . ghRepoName)
            (commitInfo ^. commit)
            branch
    case (allowDuplicateRun, pushResult) of
      (False, Just DB.AlreadyPushed) -> do
        log Informational "handleCommit: This repoOwner, repoName, commit, branch combination has already been pushed before. Skipping build"
        emptyPromise
      (False, Nothing) -> do
        log Informational "handleCommit: CommitInfo is missing branch, but allowDuplicateRun is set. Skipping build"
        emptyPromise
      (False, Just DB.NewPush) -> do
        buildFlake reporter commitInfo <?> "Build flake"
      (True, _) -> do
        buildFlake reporter commitInfo <?> "Build flake"

handleRerun :: (HasCallStack) => RerunEvent -> M ()
handleRerun ev = do
  hostname <- view #hostname
  build' <- DB.makeNewBuildForGithubRunId (ev ^. #reqUser) (ev ^. #ghRunId) hostname
  withSpan (build' ^. id) $ do
    let commitInfo =
          CommitInfo
            { _commitInfoReqUser = ev ^. #reqUser,
              _commitInfoRepoPublicity = ev ^. #repoIsPublic,
              _commitInfoRepoInfo = RepoInfo ForgeGithub (Just (ev ^. #installAuth)) (ev ^. #token) (build' ^. repoUser) (build' ^. repoName),
              _commitInfoBranch = build' ^. branch,
              _commitInfoPrFromFork = build' ^. prFromFork,
              _commitInfoCommit = build' ^. gitCommit
            }
    let reporter = openSearchReporter <> mkGithubReporter (commitInfo ^. repoInfo) (commitInfo ^. commit)
    assertIsAllowedToBuild (build' ^. repoUser) (build' ^. repoName)
    withSpan commitInfo $ rerunBuild reporter build' commitInfo

-- | Reconstruct the CommitInfo + status reporter for an existing build row,
-- forge-aware. Used by the restart endpoints, which unlike the webhook
-- handlers have no event payload to draw auth from.
commitInfoForBuild :: GhLogin -> Build -> M (CommitInfo, Reporter)
commitInfoForBuild reqUser' build = do
  repoInfo' <- case build ^. forge of
    ForgeGitea -> do
      cfg <- requireGiteaConfig
      pure $ RepoInfo ForgeGitea Nothing (GhToken (_giteaConfigApiToken cfg)) (build ^. repoUser) (build ^. repoName)
    ForgeGithub -> do
      installationId <- getGarnixInstallationId (build ^. repoUser) (build ^. repoName)
      iAuth <- case installationId of
        Nothing -> throw $ OtherError "Failed to look up installation auth for restart"
        Just installationId' -> getInstallation (Id $ fromInteger installationId')
      token <- getAccessToken iAuth
      pure $ RepoInfo ForgeGithub (Just iAuth) token (build ^. repoUser) (build ^. repoName)
  reporter <- case build ^. forge of
    ForgeGitea -> do
      cfg <- requireGiteaConfig
      pure $ openSearchReporter <> mkGiteaReporter cfg repoInfo' (build ^. gitCommit)
    ForgeGithub -> pure $ openSearchReporter <> mkGithubReporter repoInfo' (build ^. gitCommit)
  let commitInfo =
        CommitInfo
          { _commitInfoReqUser = reqUser',
            _commitInfoRepoPublicity = build ^. Types.repoIsPublic,
            _commitInfoRepoInfo = repoInfo',
            _commitInfoBranch = build ^. branch,
            _commitInfoPrFromFork = build ^. prFromFork,
            _commitInfoCommit = build ^. gitCommit
          }
  pure (commitInfo, reporter)

-- | Restart a single (typically failed) build: clone its row into a fresh
-- pending build and re-run just that package. Forge-agnostic sibling of
-- 'handleRerun' (which is driven by GitHub check-run webhooks and keyed on
-- the GitHub run id Gitea builds don't have).
restartBuild :: (HasCallStack) => GhLogin -> Build -> M ()
restartBuild reqUser' oldBuild = do
  hostname <- view #hostname
  build' <- DB.makeNewBuildForBuildId reqUser' (oldBuild ^. id) hostname
  withSpan (build' ^. id) $ do
    (commitInfo, reporter) <- commitInfoForBuild reqUser' build'
    assertIsAllowedToBuild (build' ^. repoUser) (build' ^. repoName)
    withSpan commitInfo $ rerunBuild reporter build' commitInfo

-- | Re-run the whole commit (fresh eval, then all builds/actions). Used when
-- the failure is the eval/overall build itself, which has no per-package
-- build to restart.
restartCommit :: (HasCallStack) => GhLogin -> Build -> M ()
restartCommit reqUser' build = do
  (commitInfo, reporter) <- commitInfoForBuild reqUser' build
  assertIsAllowedToBuild (build ^. repoUser) (build ^. repoName)
  void $ handleCommit reporter True commitInfo

assertIsAllowedToBuild :: GhRepoOwner -> GhRepoName -> M ()
assertIsAllowedToBuild owner repo = do
  isDenied <- DB.isDenylisted owner repo
  when isDenied $ do
    throw IsDeniedAccess

-- | Branches offered by the manual "Trigger Builds" picker, forge-aware:
--
--   * GitHub: all branches, live from the GitHub API (so you can trigger a
--     branch that has never been built).
--   * Gitea: the distinct branches garnix has already seen for this repo
--     (there is no Gitea branch-list API wired up), newest first.
listRepoBranches :: (HasCallStack) => GhRepoOwner -> GhRepoName -> M [Branch]
listRepoBranches owner repo = do
  commits <- DB.getCommitsByOwnerAndRepo owner repo
  case repoForgeFromCommits commits of
    ForgeGithub -> do
      (_, token) <- githubInstallationAuth owner repo
      listBranchesGithub token owner repo
    ForgeGitea -> pure . nub . catMaybes $ map (^. branch) commits

-- | Manually trigger a build for the latest commit on a branch, forge-aware:
--
--   * GitHub: resolve the branch's live HEAD and run a fresh eval for it.
--   * Gitea: re-run the latest commit garnix already has for that branch
--     (reusing the restart path); errors if the branch was never built.
--
-- Returns the commit that was (re)built. The caller must already have checked
-- access; 'publicity' is threaded into the GitHub CommitInfo.
triggerBranchBuild :: (HasCallStack) => GhLogin -> RepoPublicity -> GhRepoOwner -> GhRepoName -> Branch -> M CommitHash
triggerBranchBuild reqUser' publicity owner repo targetBranch = do
  assertIsAllowedToBuild owner repo
  commits <- DB.getCommitsByOwnerAndRepo owner repo
  case repoForgeFromCommits commits of
    ForgeGithub -> do
      (iAuth, token) <- githubInstallationAuth owner repo
      commit <- getHeadCommit token owner repo targetBranch
      let repoInfo' = RepoInfo ForgeGithub (Just iAuth) token owner repo
          commitInfo =
            CommitInfo
              { _commitInfoReqUser = reqUser',
                _commitInfoRepoPublicity = publicity,
                _commitInfoRepoInfo = repoInfo',
                _commitInfoBranch = Just targetBranch,
                _commitInfoPrFromFork = Nothing,
                _commitInfoCommit = commit
              }
          reporter = openSearchReporter <> mkGithubReporter repoInfo' commit
      void $ handleCommit reporter True commitInfo
      pure commit
    ForgeGitea -> do
      builds <- DB.getLatestBuildsForBranch owner repo targetBranch
      case builds of
        [] -> throw . OtherError $ "No prior build to re-trigger for Gitea branch " <> cs targetBranch
        (b : _) -> do
          (commitInfo, reporter) <- commitInfoForBuild reqUser' b
          void $ handleCommit reporter True commitInfo
          pure (b ^. gitCommit)

repoForgeFromCommits :: [CommitSummary] -> Forge
repoForgeFromCommits commits = case commits of
  (c : _) -> c ^. forge
  [] -> ForgeGithub

-- | GitHub installation auth + access token for a repo, or a clear error if
-- the garnix App is not installed on it.
githubInstallationAuth :: (HasCallStack) => GhRepoOwner -> GhRepoName -> M (GH.InstallationAuth, GhToken)
githubInstallationAuth owner repo = do
  installationId <-
    getGarnixInstallationId owner repo
      >>= maybe (throw . OtherError $ "No GitHub App installation for " <> show owner <> "/" <> show repo) pure
  iAuth <- getInstallation (Id $ fromInteger installationId)
  token <- getAccessToken iAuth
  pure (iAuth, token)
