-- Deploy garnix:add-auto-cancel-superseded to pg
-- Per-repo opt-in: when a new deployable push arrives for the same
-- (owner, repo, branch) [or, analogously, the same PR], cancel older
-- not-yet-finished builds/deploy work for that repo instead of racing them.
-- Default false so existing behavior (queue, don't cancel) is unchanged.
--
-- UNUSED BY DESIGN as of the "autoCancelSuperseded moves to garnix.yaml"
-- rework: this Configure-page-driven column is no longer read or written by
-- the application. The feature now lives entirely in garnix.yaml (top-level
-- `autoCancelSuperseded`, alongside the pre-existing `cancelSupersededBuilds`)
-- and is decided from the pushed commit's own parsed config — see
-- Garnix.Build.Flake.supersededCancellationScope. Left in place (already
-- deployed; dropping it is unnecessary churn) rather than reverted.
BEGIN;

ALTER TABLE repo_config
  ADD COLUMN IF NOT EXISTS auto_cancel_superseded boolean NOT NULL DEFAULT false;

COMMIT;
