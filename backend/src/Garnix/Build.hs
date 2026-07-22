module Garnix.Build
  ( buildFlake,
    rerunBuild,
    rerunBuilds,
    sameRerunScope,
    buildModule,
  )
where

import Control.Concurrent.Async.Lifted
import Cradle hiding (ExitCode)
import Garnix.Async
import Garnix.Build.Checkout (withAuthorization)
import Garnix.Build.Checkout qualified as Checkout
import Garnix.Build.Flake
import Garnix.Build.FodCheck qualified as FodCheck
import Garnix.Build.Helpers
import Garnix.Build.MetaCheck qualified as MetaCheck
import Garnix.Build.Module qualified as Module
import Garnix.Build.Package (doBuild)
import Garnix.Build.Reporting
import Garnix.DB qualified as DB
import Garnix.DB.ModuleValues qualified as ModuleValues
import Garnix.Entitlements qualified as Entitlements
import Garnix.GiteaInterface (giteaDoesFileExist, requireGiteaConfig)
import Garnix.Monad
import Garnix.Monad.Async (emptyPromise, joinAll_, resolve, spawn)
import Garnix.Monad.Concurrency
import Garnix.Prelude
import Garnix.Reporters.GithubReporter (mkGithubReporter)
import Garnix.Reporters.OpenSearchReporter (openSearchReporter)
import Garnix.Types as Types
import Garnix.YamlConfig (flakeDir)

buildModule :: GhLogin -> ModuleValues.GetRepoAndModuleValues -> M CommitInfo
buildModule reqUser modules = do
  commitInfo <- Module.getCommitInfo reqUser modules
  let reporter = openSearchReporter <> mkGithubReporter (commitInfo ^. repoInfo) (commitInfo ^. commit)
  ensureNoFlakeOnCommit commitInfo
  let defaultBranch = maybe (Branch "main") identity $ commitInfo ^. branch
      remote = Module.remoteWithFlake defaultBranch modules Checkout.remoteWithConfig
  forkM $ runBuildFlake reporter ModulePreview commitInfo remote
  pure commitInfo
  where
    ensureNoFlakeOnCommit :: CommitInfo -> M ()
    ensureNoFlakeOnCommit commitInfo =
      doesRepoFileExist commitInfo "flake.nix" >>= \case
        FileExists -> do
          log Informational "flake.nix already exists - skipping."
          throw ModuleErrorFlakeExists
        _ -> pure ()

-- | Build the flake, sending updates to github and the DB as you go along.
--
-- N.B.: This function should return as quickly as possible so the connection
-- can be closed.
-- | Check whether a file exists in the repo at this commit, dispatched by
-- forge: GitHub via its contents API, Gitea via its contents API. (The bare
-- 'doesRepoFileExist' is GitHub-only and 401s for a Gitea repo.)
doesRepoFileExistForge :: (HasCallStack) => CommitInfo -> FilePath -> M DoesFileExist
doesRepoFileExistForge commitInfo path =
  case commitInfo ^. repoInfo . forge of
    ForgeGithub -> doesRepoFileExist commitInfo path
    ForgeGitea -> do
      cfg <- requireGiteaConfig
      giteaDoesFileExist
        cfg
        (commitInfo ^. repoInfo . ghRepoOwner)
        (commitInfo ^. repoInfo . ghRepoName)
        (effectiveForgeRef commitInfo)
        path

buildFlake :: (HasCallStack) => Reporter -> CommitInfo -> M (Promise ())
buildFlake = curry $ mockable #buildFlakeMock $ \(reporter, commitInfo) -> do
  filesExist <-
    concurrently
      (doesRepoFileExistForge commitInfo "flake.nix")
      (doesRepoFileExistForge commitInfo "garnix.yaml")
  case filesExist of
    (FileDoesntExist, FileDoesntExist) -> do
      log Informational "No flake.nix or garnix.yaml - skipping."
      emptyPromise
    _ -> spawn $ runBuildFlake reporter Webhook commitInfo Checkout.remoteWithConfig

rerunBuild :: Reporter -> Build -> CommitInfo -> M ()
rerunBuild reporter build commitInfo = do
  runPreparedBuild reporter build commitInfo $ \runReporter build' -> do
    repoConfig <- DB.getRepoConfig (commitInfo ^. repoInfo . ghRepoOwner) (commitInfo ^. repoInfo . ghRepoName)
    plan <- Entitlements.getPlan (build ^. repoUser) >>= Entitlements.applyConfiguredTimeouts repoConfig
    Checkout.runWithCheckout Checkout.remoteWithConfig commitInfo $ \config -> do
      withAuthorization (config ^. flakeDir) repoConfig commitInfo $ do
        reportBuildResult runReporter build'
        void $ withInternalCacheToken (commitInfo ^. reqUser) $ do
          FodCheck.withFodChecker reporter commitInfo plan $ \fodChecker -> do
            doBuild fodChecker runReporter Webhook (config ^. flakeDir) repoConfig plan build'
        MetaCheck.update reporter commitInfo

-- | Re-run several existing build rows from the same commit under one
-- checkout and one FOD coordinator. Startup recovery uses this so a backend
-- restart creates one replacement "FOD checks" run for the interrupted
-- commit, rather than one per package.
rerunBuilds :: Reporter -> [Build] -> CommitInfo -> M ()
rerunBuilds _ [] _ = pure ()
rerunBuilds reporter builds@(firstBuild : _) commitInfo = do
  unless (all (sameRerunScope firstBuild) builds)
    $ throw
    $ OtherError "Cannot share a rerun scope across different commits or authorization contexts"
  metaCheckRun <- MetaCheck.newReport reporter commitInfo
  flip catchEither (\err -> MetaCheck.updateFail commitInfo metaCheckRun (Just err) >> rethrowEither err) $ do
    repoConfig <- DB.getRepoConfig (commitInfo ^. repoInfo . ghRepoOwner) (commitInfo ^. repoInfo . ghRepoName)
    plan <- Entitlements.getPlan (firstBuild ^. repoUser) >>= Entitlements.applyConfiguredTimeouts repoConfig
    Checkout.runWithCheckout Checkout.remoteWithConfig commitInfo $ \config -> do
      withAuthorization (config ^. flakeDir) repoConfig commitInfo $ do
        withInternalCacheToken (commitInfo ^. reqUser) $ do
          FodCheck.withFodChecker reporter commitInfo plan $ \fodChecker -> do
            promises <- forM builds $ \build ->
              spawn $ runPreparedBuild reporter build commitInfo $ \runReporter build' -> do
                reportBuildResult runReporter build'
                void $ doBuild fodChecker runReporter Webhook (config ^. flakeDir) repoConfig plan build'
            resolve =<< joinAll_ promises
          freshBuilds <-
            DB.getBuildsByCommit
              (commitInfo ^. repoInfo . ghRepoOwner)
              (commitInfo ^. repoInfo . ghRepoName)
              (commitInfo ^. commit)
          continued <- continueRecoveredBuilds reporter commitInfo config freshBuilds
          if continued
            then MetaCheck.updateSuccess commitInfo metaCheckRun
            else MetaCheck.updateFail commitInfo metaCheckRun Nothing

-- | Equality boundary for resources shared by 'rerunBuilds'. In particular,
-- repo publicity and requesting user are cache-authorization boundaries, so
-- they must never be coalesced merely because the commit hash matches.
sameRerunScope :: Build -> Build -> Bool
sameRerunScope = (==) `on` rerunScope

data RerunScope = RerunScope Forge GhRepoOwner GhRepoName CommitHash (Maybe Branch) (Maybe PrFromFork) RepoPublicity GhLogin
  deriving stock (Eq)

rerunScope :: Build -> RerunScope
rerunScope build =
  RerunScope
    (build ^. forge)
    (build ^. repoUser)
    (build ^. repoName)
    (build ^. gitCommit)
    (build ^. branch)
    (build ^. prFromFork)
    (build ^. Types.repoIsPublic)
    (build ^. Types.reqUser)

runPreparedBuild :: Reporter -> Build -> CommitInfo -> (RunReporter -> Build -> M ()) -> M ()
runPreparedBuild reporter build commitInfo action = do
  MetaCheck.update reporter commitInfo
  runReporter <-
    createNewRun reporter (ReportBuild (reportNameForBuild build) build)
      >>= markRunningOnFirstLog build
  let build' = build & githubRunId .~ Garnix.Monad.ghRunId runReporter
  DB.reportBuildResultDB build' <?> "Adding build github ID to DB"
  reportOnError runReporter build' commitInfo $ action runReporter build'
