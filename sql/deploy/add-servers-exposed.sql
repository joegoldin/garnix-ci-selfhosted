-- Deploy garnix:add-servers-exposed to pg
-- Records per-server SSH/port exposure from garnix.yaml sshExpose/ports:
--   {"ssh_port": 2201|null,
--    "tcp":  [{"name":"db",  "guest":5432, "host":32001}],
--    "http": [{"name":"api", "port":8080}]}
-- Idempotent (IF NOT EXISTS) so it no-ops where already applied out-of-band.

BEGIN;

ALTER TABLE servers
  ADD COLUMN IF NOT EXISTS exposed jsonb;

COMMIT;
