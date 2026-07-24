-- Deploy garnix:add-manual-deploy-target to pg
-- Records that a redeploy of a specific commit should touch only ONE package's
-- deployment. When set, the deploy planner (Garnix.Hosting.Deploy.getDeployPlan)
-- restricts the rollout to that package and leaves the repo's other running
-- deployments in place, instead of redeploying every deployment on the branch/PR.
-- Keyed by the commit that carries the rollout (a synthetic manual-<ts> id for a
-- branch redeploy, or the config's own commit for a PR redeploy). No FK to
-- commits: the row is written before the commit row exists. Idempotent.

BEGIN;

CREATE TABLE IF NOT EXISTS manual_deploy_target (
  repo_user text NOT NULL,
  repo_name text NOT NULL,
  git_commit text NOT NULL,
  package_name text NOT NULL,
  PRIMARY KEY (repo_user, repo_name, git_commit)
);

COMMIT;
