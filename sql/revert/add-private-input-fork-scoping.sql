-- Revert garnix:add-private-input-fork-scoping from pg
BEGIN;
DROP TABLE IF EXISTS private_input_fork_requests;
COMMIT;
