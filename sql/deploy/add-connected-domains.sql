-- Deploy garnix:add-connected-domains to pg
-- Operator-registered base/custom domains for hosting; DNS-points-here verified.
BEGIN;
CREATE TABLE connected_domains (
  id           bigserial PRIMARY KEY,
  domain       character varying NOT NULL UNIQUE,
  is_wildcard  boolean NOT NULL DEFAULT true,
  verified_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);
COMMIT;
