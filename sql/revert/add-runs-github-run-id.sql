-- Revert garnix:add-runs-github-run-id from pg
BEGIN;
ALTER TABLE runs DROP COLUMN github_run_id;
COMMIT;
