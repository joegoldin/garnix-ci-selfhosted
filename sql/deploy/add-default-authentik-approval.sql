-- Deploy garnix:add-default-authentik-approval to pg
-- Gate `authentik: default` hosting (which shares garnix's own OIDC client
-- credentials with a deployed guest) behind explicit admin approval per repo.
BEGIN;
ALTER TABLE repo_config
  ADD COLUMN IF NOT EXISTS default_authentik_approved boolean NOT NULL DEFAULT false;
COMMIT;
