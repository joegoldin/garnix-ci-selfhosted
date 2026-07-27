-- Revert garnix:add-auto-cancel-superseded from pg
BEGIN;
ALTER TABLE repo_config DROP COLUMN IF EXISTS auto_cancel_superseded;
COMMIT;
