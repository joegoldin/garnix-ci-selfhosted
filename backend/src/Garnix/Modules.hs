module Garnix.Modules
  ( publish,
  )
where

import Data.Row ((.+), (.==))
import Garnix.BuildLogs.Types (mkLogLine)
import Garnix.DB qualified as DB
import Garnix.DB.ModuleValues qualified as DB
import Garnix.Modules.Schema qualified as ModuleSchema
import Garnix.Monad
import Garnix.Prelude
import Garnix.Reporters.Utils (withRunReporter)
import Garnix.Types
import Garnix.YamlConfig qualified as Config

-- | Assumes Env ^. #workingDir is correctly set, i.e., we're running within `withCheckout`.
publish :: Reporter -> Config.GarnixConfig -> CommitInfo -> M ()
publish reporter config commitInfo = withTextSpan ("modules_publish", show publishEnabled) $ do
  case (publishEnabled, commitInfo ^. branch) of
    (True, Just "main") -> do
      run <- DB.newRun "Garnix module publish" commitInfo
      withRunReporter reporter (ReportRun run) $ \runReporter -> do
        modulesOrg' <- view #modulesOrg
        let repo = commitInfo ^. repoInfo
            repoOwner = getGhLogin (getGhRepoOwner (repo ^. ghRepoOwner))
        if repoOwner == modulesOrg'
          then do
            schema <- view #workingDir >>= ModuleSchema.readModuleSchema
            let repoName = repo ^. ghRepoName . to getGhRepoName
                moduleName = ModuleSchema.repoNameToModuleName repoName
            DB.insertLatestVersion
              $ (#name .== moduleName)
              .+ (#repo_user .== repo ^. ghRepoOwner)
              .+ (#repo_name .== repo ^. ghRepoName)
              .+ (#git_commit .== commitInfo ^. commit)
              .+ (#schema .== toJSON schema)
              .+ (#description .== ModuleSchema.description schema)
            reportLogs runReporter $ mkLogLine $ "Module " <> moduleName <> " updated successfully!"
            reportComplete runReporter RunReportStatusSuccess
          else
            throw $ OtherError $ "Publishing modules is not enabled for " <> repoOwner <> "."
    _ ->
      log Informational "Modules: skipping publish"
  where
    publishEnabled :: Bool
    publishEnabled = config ^. Config.moduleSection . #publish
