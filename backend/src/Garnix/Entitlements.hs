-- | In this self-hosting fork there is no billing and there are no plan limits.
-- The only thing a "plan" still carries is the evaluation/build timeout, which
-- is a safety limit driven by the Configure page. 'getPlan' returns a fixed
-- plan (unlimited timeouts) and 'applyConfiguredTimeouts' narrows it to the
-- operator-configured cap.
module Garnix.Entitlements
  ( getPlan,
    defaultProductPlan,
    applyConfiguredTimeouts,
    defaultBuildTimeoutMinutes,
    getConfiguredEvalTimeout,
  )
where

import Garnix.DB qualified as DB
import Garnix.Duration (Duration, fromMinutes)
import Garnix.Monad (M)
import Garnix.Prelude
import Garnix.Types

-- | The single plan every repo is on. Timeouts start maxed out and are then
-- narrowed by 'applyConfiguredTimeouts'. DisplayName/description are only shown
-- on the account usage page.
defaultProductPlan :: ProductPlan
defaultProductPlan =
  ProductPlan
    { _productPlanDisplayName = "Self-Hosted",
      _productPlanDescription = Just "Self-hosted garnix",
      _productPlanPackageEvaluationTimeout = maxBound,
      _productPlanPackageBuildTimeout = maxBound
    }

getPlan :: GhRepoOwner -> M ProductPlan
getPlan _ = pure defaultProductPlan

-- | Build/eval cap (minutes) applied when nothing is configured anywhere.
defaultBuildTimeoutMinutes :: Int32
defaultBuildTimeoutMinutes = 60

-- | Apply the operator-configured build/eval timeout (from the self-host
-- Configure page) on top of a plan. A per-repo override wins over the global
-- default, which wins over the plan's own timeout; when neither is set a 1-hour
-- default cap is applied. The same cap is applied to both the evaluation and
-- build phases, clamped to the Int16 minute range the plan fields use.
applyConfiguredTimeouts :: RepoConfig -> ProductPlan -> M ProductPlan
applyConfiguredTimeouts repoConfig plan = do
  globalDefault <- DB.getDefaultBuildTimeout
  let mMinutes = case repoConfig ^. buildTimeoutMinutes of
        Just m -> Just m
        Nothing -> globalDefault
      setTimeout minutes =
        plan
          & packageBuildTimeout .~ minutes
          & packageEvaluationTimeout .~ minutes
  pure $ case mMinutes of
    -- Nothing set (repo or global): default cap of 1 hour.
    Nothing -> setTimeout (fromIntegral defaultBuildTimeoutMinutes)
    -- 0 explicitly means "no limit".
    Just 0 -> setTimeout maxBound
    Just minutes -> setTimeout (fromIntegral (min 32767 (max 1 minutes)))

-- | The configured evaluation timeout for a repo as a 'Duration' (per-repo
-- override > Configure-page global default > 1 h; 0 = no limit). Applied to
-- the pre-build nix commands (config eval, attr discovery, flake metadata) so
-- a wedged nix-daemon fails the push instead of leaving it at "Build
-- starting" forever.
getConfiguredEvalTimeout :: GhRepoOwner -> GhRepoName -> M Duration
getConfiguredEvalTimeout owner name = do
  repoConfig <- DB.getRepoConfig owner name
  plan <- getPlan owner >>= applyConfiguredTimeouts repoConfig
  pure $ fromMinutes $ plan ^. packageEvaluationTimeout
