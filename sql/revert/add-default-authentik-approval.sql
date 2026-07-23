-- Revert garnix:add-default-authentik-approval from pg
BEGIN;
ALTER TABLE repo_config DROP COLUMN IF EXISTS default_authentik_approved;
COMMIT;
