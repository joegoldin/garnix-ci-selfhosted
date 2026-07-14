-- Deploy garnix:add-builds-run-started-at to pg
-- Records when a build actually starts executing, as opposed to when the build
-- row is first created (which happens while it is still queued/pending). A
-- nullable timestamp lets us distinguish "pending" (status IS NULL AND
-- run_started_at IS NULL) from "running" (status IS NULL AND run_started_at IS
-- NOT NULL). Idempotent (IF NOT EXISTS) so it no-ops where already applied.

BEGIN;

ALTER TABLE builds ADD COLUMN IF NOT EXISTS run_started_at timestamptz;

COMMIT;
