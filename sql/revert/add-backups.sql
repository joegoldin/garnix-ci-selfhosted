-- Revert garnix:add-backups from pg

BEGIN;

ALTER TABLE servers DROP COLUMN IF EXISTS backups;
ALTER TABLE repo_config
  DROP COLUMN IF EXISTS backup_retention_days,
  DROP COLUMN IF EXISTS backup_keep_latest;
ALTER TABLE server_settings
  DROP COLUMN IF EXISTS backup_retention_days,
  DROP COLUMN IF EXISTS backup_keep_latest;
DROP TABLE IF EXISTS backup_restores;
DROP TABLE IF EXISTS backups;
DROP TABLE IF EXISTS backup_objects;

COMMIT;
