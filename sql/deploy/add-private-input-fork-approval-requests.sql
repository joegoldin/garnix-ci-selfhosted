-- Deploy garnix:add-private-input-fork-approval-requests to pg
-- A trusted self-host build may use private inputs automatically. When an
-- external fork first attempts that, remember the block so the admin UI can
-- show an approval control only for repositories that actually need one.

BEGIN;

ALTER TABLE repo_config
  ADD COLUMN IF NOT EXISTS private_input_fork_blocked_at timestamp with time zone;

-- The old flag meant "allow this public base repo to use private inputs".
-- Trusted self-host builds no longer need that exemption, and carrying the
-- value forward would silently turn it into permission for arbitrary external
-- forks without ever creating a visible approval request. Clear it once;
-- private_cache remains untouched.
UPDATE repo_config
SET skip_private_inputs_check_for_collaborators = FALSE
WHERE skip_private_inputs_check_for_collaborators;

COMMIT;
