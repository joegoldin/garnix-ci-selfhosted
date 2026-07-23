-- Deploy garnix:add-private-input-fork-scoping to pg
-- Per-fork private-input approval: approving one external fork must not trust
-- all future forks of a repo. Track each (base repo, fork) pair separately.
BEGIN;
CREATE TABLE IF NOT EXISTS private_input_fork_requests (
  repo_user text NOT NULL,
  repo_name text NOT NULL,
  fork_full_name text NOT NULL,
  blocked_at timestamp with time zone NOT NULL DEFAULT now(),
  approved_at timestamp with time zone,
  PRIMARY KEY (repo_user, repo_name, fork_full_name)
);
COMMIT;
