-- Deploy garnix:add-server-domains to pg
-- Extra declared hostnames a deployed server answers on (vanity/custom domains).
BEGIN;
ALTER TABLE servers ADD COLUMN IF NOT EXISTS domains jsonb NOT NULL DEFAULT '[]'::jsonb;
COMMIT;
