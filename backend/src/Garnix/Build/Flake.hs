module Garnix.Build.Flake
  ( runBuildFlake,
    continueRecoveredBuilds,
    supersededCancellationScope,
  )
where

import Control.Lens
import Garnix.Artifacts qualified as Artifacts
import Garnix.Attribute
import Garnix.Build.Action qualified as Action
import Garnix.Build.Checkout (Remote, runWithCheckout, withAuthorization)
import Garnix.Build.FodCheck qualified as FodCheck
import Garnix.Build.Helpers
import Garnix.Build.MetaCheck qualified as MetaCheck
import Garnix.Build.Package (doBuild)
import Garnix.Build.Reporting
import Garnix.DB qualified as DB
import Garnix.Entitlements (applyConfiguredTimeouts, getPlan)
import Garnix.GetAttributes
import Garnix.Hosting.Deploy (rolloutNewServerVersion)
import Garnix.Modules qualified as Modules
import Garnix.Monad
import Garnix.Monad.Async (joinAll, joinAll_, resolve, spawn)
import Garnix.Prelude
import Garnix.Types as Types
import Garnix.YamlConfig (Action, ExcludeBranches (..), GarnixConfig, IncrementalizeBuildsSection (..), artifacts, autoCancelSuperseded, flakeDir, incrementalizeBuildsSection)

runBuildFlake :: (HasCallStack) => Reporter -> BuildKind -> CommitInfo -> Remote -> M ()
runBuildFlake reporter buildKind commitInfo withCheckout = do
  let repoOwner = commitInfo ^. repoInfo . ghRepoOwner
  (startingBuild, startingBuildRunReporter) <- newBuild reporter commitInfo (PackageInfo TypeOverall NoSystem buildStarting) False
  withInternalCacheToken (commitInfo ^. reqUser) $ do
    metaCheckRun <- MetaCheck.newReport reporter commitInfo
    flip catchEither (\err -> MetaCheck.updateFail commitInfo metaCheckRun (Just err) >> rethrowEither err) $ do
      reportOnError startingBuildRunReporter startingBuild commitInfo $ do
        repoConfig <- DB.getRepoConfig (commitInfo ^. repoInfo . ghRepoOwner) (commitInfo ^. repoInfo . ghRepoName)
        runWithCheckout withCheckout commitInfo $ \config -> do
          -- Driven entirely by the NEW commit's own parsed garnix.yaml
          -- (config's autoCancelSuperseded flag; see
          -- 'supersededCancellationScope'). Run this as early as possible
          -- once 'config' is known, ahead of 'withAuthorization' and
          -- 'getPlan' below, so a superseded older push is cancelled
          -- without waiting on unrelated (and possibly slow)
          -- authorization/entitlement work first.
          forM_
            (supersededCancellationScope config (commitInfo ^. branch) (commitInfo ^. prFromFork))
            $ \scope ->
              DB.cancelSupersededWork
                (commitInfo ^. repoInfo . ghRepoOwner)
                (commitInfo ^. repoInfo . ghRepoName)
                scope
                (commitInfo ^. commit)
                (startingBuild ^. startTime)
          withAuthorization (config ^. flakeDir) repoConfig commitInfo $ do
            plan <- getPlan repoOwner >>= applyConfiguredTimeouts repoConfig
            initialBuilds <- setupBuilds reporter commitInfo config plan
            initialActions <- setupActions reporter commitInfo config
            updatedBuild <-
              liftIO getCurrentTime <&> \now ->
                startingBuild
                  & status ?~ Success
                  & endTime ?~ now
            DB.setCommitStatus (commitInfo ^. repoInfo . ghRepoOwner) (commitInfo ^. repoInfo . ghRepoName) (commitInfo ^. commit) Evaluated
            reportBuildResult startingBuildRunReporter updatedBuild

            FodCheck.withFodChecker reporter commitInfo plan $ \fodChecker -> do
              buildPromises <- forM initialBuilds $ \(initialBuild, runReporter) -> do
                spawn $ doBuild fodChecker runReporter buildKind (config ^. flakeDir) repoConfig plan initialBuild
              actionPromises <- forM initialActions $ \(initialBuild, runReporter, actionConfig) -> do
                spawn
                  $ buildAndRunAction
                    reporter
                    fodChecker
                    runReporter
                    commitInfo
                    buildKind
                    plan
                    (config ^. flakeDir)
                    repoConfig
                    initialBuild
                    actionConfig
              builds <- joinAll buildPromises >>= resolve
              Artifacts.publishArtifacts config builds
              joinAll_ actionPromises >>= resolve

              let allBuildsSucceeded = all (\build -> build ^. status == Just Success) builds

              when allBuildsSucceeded $ do
                Modules.publish reporter config commitInfo

              deployments <- case (commitInfo ^. prFromFork, commitInfo ^. branch) of
                (Nothing, Nothing) -> do
                  log Critical "Both branch and fork info are missing. Expected exactly one to be present."
                  pure []
                (Just _, Just _) -> do
                  log Critical "Both branch and fork info are present. Expected exactly one to be present."
                  pure []
                (Nothing, Just (branch :: Branch)) -> do
                  if allBuildsSucceeded
                    then do
                      rolloutNewServerVersion reporter commitInfo (BranchDeployment branch)
                    else pure []
                (Just (_ :: PrFromFork), Nothing) -> do
                  log Notice "PR is from fork. Not deploying servers"
                  pure []

              let allDeploymentsSucceeded =
                    all
                      ( \serverInfo ->
                          isJust (serverInfo ^. readyAt)
                            && isNothing (serverInfo ^. endedAt)
                      )
                      deployments
              if allBuildsSucceeded && allDeploymentsSucceeded
                then MetaCheck.updateSuccess commitInfo metaCheckRun
                else MetaCheck.updateFail commitInfo metaCheckRun Nothing

-- | Pure decision logic for auto-cancel-superseded: whether (and under what
-- 'DB.SupersededScope') a push should cancel older not-yet-finished work,
-- given the NEW commit's own parsed garnix.yaml ('GarnixConfig') and its
-- branch\/fork identity. The feature is effectively on when
-- @autoCancelSuperseded@ is set (see its docs on 'GarnixConfig'). Kept
-- separate from 'runBuildFlake' (which threads its result straight into
-- 'DB.cancelSupersededWork') purely so this can be unit-tested without
-- needing a full pipeline run — see 'Garnix.Build.FlakeSpec'.
--
--   * Off entirely -> never cancel, regardless of branch\/fork.
--   * A branch push (ordinary pushes AND non-fork PR pushes, which are
--     literally pushes to a real branch on the base repo) -> scope by branch.
--   * A fork PR push (no branch at all on the base repo — see
--     'Garnix.API.GhWebhooks.ghWebhookPullRequest') -> scope by fork identity.
--   * Neither present (shouldn't happen for a real commit) -> no-op.
supersededCancellationScope :: GarnixConfig -> Maybe Branch -> Maybe PrFromFork -> Maybe DB.SupersededScope
supersededCancellationScope config = go (config ^. autoCancelSuperseded)
  where
    go False _ _ = Nothing
    go True (Just currentBranch) _ = Just (DB.SupersededBranch currentBranch)
    go True Nothing (Just fork) = Just (DB.SupersededFork fork)
    go True Nothing Nothing = Nothing

-- | Continue the idempotent tail of a commit after startup recovery has
-- finished its package rows. Action processes are deliberately not replayed:
-- their orphaned run rows are cancelled at startup because arbitrary actions
-- are not guaranteed idempotent. Artifact publication is content-addressed,
-- module publication is an upsert, and deployment planning is reconciliatory,
-- so these stages are safe to repeat.
continueRecoveredBuilds :: Reporter -> CommitInfo -> GarnixConfig -> [Build] -> M Bool
continueRecoveredBuilds reporter commitInfo config builds = do
  Artifacts.publishArtifacts config builds
  let packageBuilds = filter ((/= TypeOverall) . (^. packageType)) builds
      allBuildsSucceeded = all ((`elem` [Just Success, Just Skipped]) . (^. status)) packageBuilds
  when allBuildsSucceeded $ Modules.publish reporter config commitInfo
  deployments <- case (commitInfo ^. prFromFork, commitInfo ^. branch) of
    (Nothing, Just branch) ->
      if allBuildsSucceeded
        then rolloutNewServerVersion reporter commitInfo (BranchDeployment branch)
        else pure []
    (Just _, Nothing) -> do
      log Notice "Recovered PR is from a fork. Not deploying servers"
      pure []
    _ -> do
      log Critical "Recovered commit has inconsistent branch/fork metadata; not deploying servers"
      pure []
  let allDeploymentsSucceeded =
        all
          (\serverInfo -> isJust (serverInfo ^. readyAt) && isNothing (serverInfo ^. endedAt))
          deployments
  pure (allBuildsSucceeded && allDeploymentsSucceeded)

setupBuilds :: Reporter -> CommitInfo -> GarnixConfig -> ProductPlan -> M [(Build, RunReporter)]
setupBuilds reporter commitInfo config _plan = do
  -- No per-plan package limit in this fork.
  toBuild <- getAttributesToBuild commitInfo config
  -- garnix.yaml `artifacts:` packages are built even when the build sections
  -- don't include them (mirroring how actions auto-include their apps).
  let artifactAttr section =
        Attribute
          { _attributePackageType = TypePackage,
            _attributeSystem = Just X8664Linux,
            _attributePackageName = Just (section ^. package),
            _attributeExtension = Nothing
          }
      withArtifacts = toBuild <> filter (`notElem` toBuild) (map artifactAttr (config ^. artifacts))
  log Informational $ "Will build the following attributes: " <> show withArtifacts
  forM withArtifacts $ \attr -> do
    setupBuild reporter config commitInfo attr

setupActions :: Reporter -> CommitInfo -> GarnixConfig -> M [(Build, RunReporter, Action)]
setupActions reporter commitInfo config = do
  log Informational $ "Will run the following actions: " <> show (Action.getActionAppAttributes config)
  forM (Action.getActionAppAttributes config) $ \(attr, actionConfig) -> do
    (build, reporter) <- setupBuild reporter config commitInfo attr
    return (build, reporter, actionConfig)

buildAndRunAction ::
  Reporter ->
  Maybe FodChecker ->
  RunReporter ->
  CommitInfo ->
  BuildKind ->
  ProductPlan ->
  FlakeDir ->
  RepoConfig ->
  Build ->
  Action ->
  M ()
buildAndRunAction reporter fodChecker runReporter commitInfo buildKind plan flakeDir repoConfig initialBuild actionConfig = do
  build <- doBuild fodChecker runReporter buildKind flakeDir repoConfig plan initialBuild
  Action.run flakeDir repoConfig reporter commitInfo (attribute build) actionConfig build

newBuild :: Reporter -> CommitInfo -> PackageInfo -> Bool -> M (Build, RunReporter)
newBuild reporter commitInfo packageInfo wantsIncrementalism = withSpan packageInfo $ do
  hostname <- view #hostname
  initialBuild <-
    DB.newBuildDB commitInfo packageInfo hostname wantsIncrementalism
      <?> "Creating a build in the DB"
  withSpan (initialBuild ^. id) $ do
    runReporter <-
      createNewRun reporter (ReportBuild (reportNameForBuild initialBuild) initialBuild)
        >>= markRunningOnFirstLog initialBuild
    log Informational $ "My GH run id is: " <> show (Garnix.Monad.ghRunId runReporter)
    let build = initialBuild & githubRunId .~ Garnix.Monad.ghRunId runReporter
    DB.reportBuildResultDB build <?> "Adding build github ID to DB"
    pure (build, runReporter)

setupBuild :: Reporter -> GarnixConfig -> CommitInfo -> Attribute -> M (Build, RunReporter)
setupBuild reporter config commitInfo attr = case attr ^. packageName of
  Nothing -> do
    throw $ OtherError "Tried to build, but no package name available"
  Just pkgName -> do
    let wantsIncrementalism' = case config ^. incrementalizeBuildsSection of
          IncrementalizeBuilds True -> True
          IncrementalizeBuilds False -> False
          IncrementalBuildsExcludeBranches (ExcludeBranches brs) -> case commitInfo ^. branch of
            Nothing -> False
            Just br -> br `notElem` brs
    (build, runReporter) <-
      newBuild
        reporter
        commitInfo
        (PackageInfo (attr ^. packageType) (attr ^. system . from maybeSystemIso) pkgName)
        wantsIncrementalism'
    pure (build, runReporter)
