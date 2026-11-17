-- Verify garnix:add-runs-github-run-id on pg
BEGIN;
SELECT github_run_id FROM runs WHERE FALSE;
ROLLBACK;
