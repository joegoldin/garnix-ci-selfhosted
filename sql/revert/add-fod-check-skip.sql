-- Revert garnix:add-fod-check-skip from pg
BEGIN;
ALTER TABLE repo_config DROP COLUMN IF EXISTS fod_check_skip;
COMMIT;
