-- Deploy garnix:add-runs-github-run-id to pg
-- Reconstructed reporters must update the original check, not create another.
BEGIN;
ALTER TABLE runs ADD COLUMN IF NOT EXISTS github_run_id bigint;
COMMIT;
