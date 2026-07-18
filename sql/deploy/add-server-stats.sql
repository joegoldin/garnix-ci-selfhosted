-- Deploy garnix:add-server-stats to pg
-- Per-deployed-server resource samples pushed by the guest reporter (CPU %,
-- memory used/total). We keep a short rolling window per server (the backend
-- prunes to the most recent N on insert) so the Servers page can show the
-- latest sample and the per-server Monitor page a small live history.

BEGIN;

CREATE TABLE server_stats (
  id           bigserial PRIMARY KEY,
  server_id    bigint NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
  sampled_at   timestamptz NOT NULL DEFAULT now(),
  cpu_pct      double precision NOT NULL,
  mem_used_kb  bigint NOT NULL,
  mem_total_kb bigint NOT NULL
);

CREATE INDEX server_stats_server_id_sampled_at_idx
  ON server_stats (server_id, sampled_at DESC);

COMMIT;
