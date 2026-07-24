-- Revert garnix:add-manual-deploy-target from pg
BEGIN;
DROP TABLE IF EXISTS manual_deploy_target;
COMMIT;
