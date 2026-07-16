-- Deploy garnix:add-runs-run-started-at to pg
-- Runs (actions, FOD checks, module publish, deployments) stay "pending"
-- until their first line of output, like builds: record when output starts.
-- Idempotent (IF NOT EXISTS) so it no-ops where already applied out-of-band.

BEGIN;

ALTER TABLE runs
  ADD COLUMN IF NOT EXISTS run_started_at timestamptz;

COMMIT;
