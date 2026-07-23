{-# LANGUAGE DuplicateRecordFields #-}

module Garnix.Orchestrator
  ( handlePullRequest,
    handleCommit,
    handleRerun,
    restartBuild,
    restartBuilds,
    restartCommit,
    resumeBuild,
    resumeBuilds,
    listRepoBranches,
    triggerBranchBuild,
    RerunEvent (..),
    groupResumableBuilds,
  )
where

import Data.Time (defaultTimeLocale, formatTime)
import Garnix.Async (Promise)
import Garnix.Build (buildFlake, rerunBuild, rerunBuilds, sameRerunScope)
import Garnix.Build.Checkout qualified as Build.Checkout
import Garnix.Build.Helpers (withInternalCacheToken)
import Garnix.DB qualified as DB
import Garnix.GiteaInterface (requireGiteaConfig)
import Garnix.GithubInterface (listBranchesGithub)
import Garnix.Hosting.Deploy (rolloutNewServerVersion)
import Garnix.Monad
import Garnix.Monad.Async (emptyPromise, resolve, spawn)
import Garnix.Monad.Concurrency (forkM)
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

-- | Clone and restart several package builds as one rerun scope. Cloning is
-- synchronous so the API exposes the fresh pending rows before returning;
-- execution is detached but shares one checkout and one FOD coordinator.
restartBuilds :: (HasCallStack) => GhLogin -> [Build] -> M ()
restartBuilds _ [] = pure ()
restartBuilds reqUser' oldBuilds = do
  hostname <- view #hostname
  builds <- forM oldBuilds $ \oldBuild ->
    DB.makeNewBuildForBuildId reqUser' (oldBuild ^. id) hostname
  case builds of
    [] -> pure ()
    build : _ -> do
      (commitInfo, reporter) <- commitInfoForBuild reqUser' build
      assertIsAllowedToBuild (build ^. repoUser) (build ^. repoName)
      forkM $ withSpan (build ^. id) $ do
        withSpan commitInfo $ rerunBuilds reporter builds commitInfo

-- | Resume package builds orphaned by a backend restart mid-flight (left
-- @status IS NULL@ -- see 'DB.getResumableOrphanedBuilds'). Unlike
-- 'restartBuild'/'restartCommit',
-- this reuses the existing build rows rather than cloning fresh ones: the
-- rows with derivation checkpoints reattach to the nix-daemon; rows interrupted
-- earlier simply repeat evaluation before building.
--
-- Best-effort: this runs unattended at startup, with nobody to retry it, so
-- any failure that would otherwise leave the build stuck @status IS NULL@
-- forever -- forge-auth lookups in 'commitInfoForBuild', or any other
-- exception before a terminal status gets reported -- cancels it instead.
-- 'catchEither' rather than plain 'catchAny' because 'commitInfoForBuild'
-- and 'rerunBuilds' report most failures via 'MonadError' ('throwError'), not
-- thrown 'SomeException's.
resumeBuild :: (HasCallStack) => GhLogin -> Build -> M ()
resumeBuild reqUser' build = resumeBuildGroup reqUser' [build]

-- | Resume all orphaned packages in one commit/auth scope together. The
-- shared rerun scope is what prevents startup recovery from creating a FOD
-- coordinator per package.
resumeBuilds :: (HasCallStack) => [Build] -> M ()
resumeBuilds [] = pure ()
resumeBuilds builds@(build : _) = resumeBuildGroup (build ^. Types.reqUser) builds

resumeBuildGroup :: (HasCallStack) => GhLogin -> [Build] -> M ()
resumeBuildGroup _ [] = pure ()
resumeBuildGroup reqUser' builds@(build : _) =
  withSpan (build ^. id) $ resume `catchEither` cancelIfStillOrphaned
  where
    resume = do
      (commitInfo, reporter) <- commitInfoForBuild reqUser' build
      assertIsAllowedToBuild (build ^. repoUser) (build ^. repoName)
      withSpan commitInfo $ rerunBuilds reporter builds commitInfo

    -- rerunBuilds already reports a terminal status for failures it observes
    -- (via reportOnError, which rethrows after reporting -- so we
    -- still land here). Re-fetch the row rather than trusting the stale
    -- in-memory `build`, so a real Failure it already reported is never
    -- clobbered with Cancelled; only a row that is genuinely still orphaned
    -- gets closed out.
    cancelIfStillOrphaned e = do
      log Error
        $ "resumeBuilds: failed to resume orphaned build group for "
        <> show (build ^. repoUser)
        <> "/"
        <> show (build ^. repoName)
        <> "@"
        <> show (build ^. gitCommit)
        <> ", cancelling any builds still orphaned: "
        <> either show showDebug e
      forM_ builds $ \orphanedBuild ->
        (DB.getBuild (orphanedBuild ^. id) >>= cancelIfNull)
          `catchEither` \e' ->
            log Error
              $ "resumeBuilds: failed to cancel orphaned build "
              <> show (orphanedBuild ^. id)
              <> " after failed group resume: "
              <> either show showDebug e'

    cancelIfNull fresh
      | isJust (fresh ^. status) = pure ()
      | otherwise = do
          now <- liftIO getCurrentTime
          DB.reportBuildResultDB (fresh & status ?~ Cancelled & endTime ?~ now)

-- | Stable, order-preserving grouping for startup recovery. A shared checkout,
-- authorization token, and FOD checker are safe only when all CommitInfo and
-- cache-auth fields are identical.
groupResumableBuilds :: [Build] -> [[Build]]
groupResumableBuilds [] = []
groupResumableBuilds (build : builds) =
  let (sameCommit, rest) = partition (sameRerunScope build) builds
   in (build : sameCommit) : groupResumableBuilds rest

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
-- The build is a *fresh* one identified by a synthetic @manual-<timestamp>@
-- commit, so re-triggering an already-built branch produces a new, distinct
-- build/commit page instead of reopening the old commit. The checkout resolves
-- a @manual-@ commit to the branch's HEAD (see 'Garnix.Build.Checkout'), so it
-- builds the branch's current tip on both GitHub and Gitea. It reports to garnix
-- (OpenSearch) only — not the forge — because the built ref is a synthetic id,
-- not a real commit. Returns the synthetic @manual-<timestamp>@ id.
triggerBranchBuild :: (HasCallStack) => GhLogin -> RepoPublicity -> GhRepoOwner -> GhRepoName -> Branch -> M CommitHash
triggerBranchBuild reqUser' publicity owner repo targetBranch = do
  assertIsAllowedToBuild owner repo
  commits <- DB.getCommitsByOwnerAndRepo owner repo
  now <- liftIO getCurrentTime
  let manualCommit = CommitHash $ cs $ formatTime defaultTimeLocale "manual-%Y%m%d-%H%M%S" now
  repoInfo' <- case repoForgeFromCommits commits of
    ForgeGithub -> do
      (iAuth, token) <- githubInstallationAuth owner repo
      pure $ RepoInfo ForgeGithub (Just iAuth) token owner repo
    ForgeGitea -> do
      cfg <- requireGiteaConfig
      pure $ RepoInfo ForgeGitea Nothing (GhToken (_giteaConfigApiToken cfg)) owner repo
  let commitInfo =
        CommitInfo
          { _commitInfoReqUser = reqUser',
            _commitInfoRepoPublicity = publicity,
            _commitInfoRepoInfo = repoInfo',
            _commitInfoBranch = Just targetBranch,
            _commitInfoPrFromFork = Nothing,
            _commitInfoCommit = manualCommit
          }
  void $ handleCommit openSearchReporter True commitInfo
  pure manualCommit

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
