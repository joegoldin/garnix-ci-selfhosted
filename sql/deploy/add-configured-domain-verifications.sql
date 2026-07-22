-- Deploy garnix:add-configured-domain-verifications to pg
-- Durable DNS-points-here status for read-only Nix-configured hosting bases.
BEGIN;

CREATE TABLE configured_domain_verifications (
  domain       character varying PRIMARY KEY,
  verified_at  timestamptz NOT NULL DEFAULT now()
);

COMMIT;
