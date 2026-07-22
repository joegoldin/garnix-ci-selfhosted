-- Revert garnix:add-configured-domain-verifications from pg
BEGIN;

DROP TABLE configured_domain_verifications;

COMMIT;
