module Garnix.Build.Flake
  ( runBuildFlake,
    continueRecoveredBuilds,
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
import Garnix.YamlConfig (Action, ExcludeBranches (..), GarnixConfig, IncrementalizeBuildsSection (..), artifacts, cancelSupersededBuilds, flakeDir, incrementalizeBuildsSection)

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
          withAuthorization (config ^. flakeDir) repoConfig commitInfo $ do
            plan <- getPlan repoOwner >>= applyConfiguredTimeouts repoConfig
            -- Opt-in via garnix.yaml: a new push supersedes older commits on
            -- the same branch, so cancel their queued/running builds.
            when (config ^. cancelSupersededBuilds) $ case commitInfo ^. branch of
              Nothing -> pure ()
              Just currentBranch ->
                DB.cancelSupersededBuilds
                  (commitInfo ^. repoInfo . ghRepoOwner)
                  (commitInfo ^. repoInfo . ghRepoName)
                  currentBranch
                  (commitInfo ^. commit)
                  (startingBuild ^. startTime)
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
