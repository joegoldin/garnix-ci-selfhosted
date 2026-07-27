-- Deploy garnix:add-auto-cancel-superseded to pg
-- Per-repo opt-in: when a new deployable push arrives for the same
-- (owner, repo, branch) [or, analogously, the same PR], cancel older
-- not-yet-finished builds/deploy work for that repo instead of racing them.
-- Default false so existing behavior (queue, don't cancel) is unchanged.
BEGIN;

ALTER TABLE repo_config
  ADD COLUMN IF NOT EXISTS auto_cancel_superseded boolean NOT NULL DEFAULT false;

COMMIT;
