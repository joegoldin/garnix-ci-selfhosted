-- Deploy garnix:rename-hetzner-id-to-provisioner-id to pg
-- This fork provisions local microVMs only; the "hetzner id" column now just
-- holds the provisioner's server id. Rename it (and the pool table's check
-- constraint) to match. Guarded so it no-ops where already renamed.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name = 'servers' AND column_name = 'hetzner_id') THEN
    ALTER TABLE servers RENAME COLUMN hetzner_id TO provisioner_id;
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name = 'server_pool' AND column_name = 'hetzner_id') THEN
    ALTER TABLE server_pool RENAME COLUMN hetzner_id TO provisioner_id;
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.table_constraints
             WHERE table_name = 'server_pool'
               AND constraint_name = 'ready_must_have_hetzner_id_and_ips') THEN
    ALTER TABLE server_pool
      RENAME CONSTRAINT ready_must_have_hetzner_id_and_ips
      TO ready_must_have_provisioner_id_and_ips;
  END IF;
END $$;

COMMIT;
