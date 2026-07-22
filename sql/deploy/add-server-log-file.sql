-- Deploy garnix:add-server-log-file to pg
-- Optional guest application-log path followed over the private deploy SSH channel.
BEGIN;
ALTER TABLE servers ADD COLUMN IF NOT EXISTS log_file text;
COMMIT;
