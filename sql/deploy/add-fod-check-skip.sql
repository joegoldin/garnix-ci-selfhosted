-- Deploy garnix:add-fod-check-skip to pg
-- Per-repo allowlist of FOD-check skip patterns: glob patterns (matched against
-- a fixed-output derivation's <name>) that `fodChecks` skips instead of failing
-- closed. Use case: nixpkgs bootstrap seeds like stage0-posix-*-source whose
-- builder is a non-executable placeholder. Idempotent (IF NOT EXISTS) so it
-- no-ops on any DB where it was already applied out-of-band.

BEGIN;

ALTER TABLE repo_config
  ADD COLUMN IF NOT EXISTS fod_check_skip text[] DEFAULT '{}' NOT NULL;

COMMIT;
