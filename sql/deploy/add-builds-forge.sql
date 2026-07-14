-- Deploy garnix:add-builds-forge to pg
-- Adds a forge discriminator to builds so GitHub and Gitea repos with the same
-- owner/name don't collide. Idempotent (IF NOT EXISTS) so it no-ops on any DB
-- where the column was already added out-of-band.

BEGIN;

ALTER TABLE builds
  ADD COLUMN IF NOT EXISTS forge character varying DEFAULT 'github'::character varying NOT NULL;

COMMIT;
