-- Deploy garnix:add-build-timeout-config to pg
-- Adds operator-configurable build/eval timeouts for self-host mode: a global
-- default (server_settings, a single row) and per-repo overrides (a nullable
-- column on repo_config). All idempotent (IF NOT EXISTS) so it no-ops on any
-- DB where these were already applied out-of-band.

BEGIN;

ALTER TABLE repo_config
  ADD COLUMN IF NOT EXISTS build_timeout_minutes integer;

-- Single-row table holding the global default build/eval timeout (minutes).
-- The CHECK on a boolean PK constrains it to exactly one row.
CREATE TABLE IF NOT EXISTS server_settings (
    singleton boolean PRIMARY KEY DEFAULT true CONSTRAINT server_settings_singleton CHECK (singleton),
    default_build_timeout_minutes integer
);

INSERT INTO server_settings (singleton) VALUES (true)
  ON CONFLICT (singleton) DO NOTHING;

COMMIT;
