-- Deploy garnix:add-server-ssh-users to pg
-- Real login usernames captured from the guest at deploy time (getent passwd).
BEGIN;
ALTER TABLE servers ADD COLUMN IF NOT EXISTS ssh_users jsonb NOT NULL DEFAULT '[]'::jsonb;
COMMIT;
