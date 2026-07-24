-- Deploy garnix:add-backups to pg
-- Scheduled server backups: snapshot rows (which deliberately OUTLIVE their
-- server via ON DELETE SET NULL + denormalized repo identity — restoring
-- after accidental server deletion is the point), content-addressed object
-- bookkeeping, restore audit rows, artifacts-style retention settings
-- (keep-latest defaults ON: retention must never delete the last snapshot),
-- and the per-server backup config captured at deploy time. Idempotent.

BEGIN;

CREATE TABLE IF NOT EXISTS backup_objects (
  object_hash text PRIMARY KEY,   -- nix-hash --base32 sha256 of the .tar.zst
  total_size  bigint NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS backups (
  id               bigserial PRIMARY KEY,
  server_id        bigint REFERENCES servers(id) ON DELETE SET NULL,
  repo_user        text NOT NULL,
  repo_name        text NOT NULL,
  branch           text,
  configuration    text NOT NULL,               -- builds.package of the deployed config
  persistence_name text,
  object_hash      text REFERENCES backup_objects(object_hash),
  status           text NOT NULL,               -- running | success | failed
  error            text,
  kind             text NOT NULL DEFAULT 'scheduled',  -- scheduled | manual
  locked           boolean NOT NULL DEFAULT false,
  size             bigint,
  started_at       timestamptz NOT NULL DEFAULT now(),
  finished_at      timestamptz
);
CREATE INDEX IF NOT EXISTS backups_repo_config_idx
  ON backups (repo_user, repo_name, configuration, started_at DESC);
CREATE INDEX IF NOT EXISTS backups_server_idx ON backups (server_id);

CREATE TABLE IF NOT EXISTS backup_restores (
  id           bigserial PRIMARY KEY,
  backup_id    bigint NOT NULL REFERENCES backups(id),
  server_id    bigint REFERENCES servers(id) ON DELETE SET NULL,
  status       text NOT NULL,                   -- running | success | failed
  error        text,
  initiated_by text NOT NULL,
  started_at   timestamptz NOT NULL DEFAULT now(),
  finished_at  timestamptz
);

ALTER TABLE server_settings
  ADD COLUMN IF NOT EXISTS backup_retention_days int NOT NULL DEFAULT 30,
  ADD COLUMN IF NOT EXISTS backup_keep_latest boolean NOT NULL DEFAULT true;

ALTER TABLE repo_config
  ADD COLUMN IF NOT EXISTS backup_retention_days int,
  ADD COLUMN IF NOT EXISTS backup_keep_latest boolean;

ALTER TABLE servers
  ADD COLUMN IF NOT EXISTS backups jsonb;

COMMIT;
