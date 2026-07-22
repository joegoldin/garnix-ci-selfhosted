-- Verify garnix:add-configured-domain-verifications on pg
BEGIN;

SELECT domain, verified_at
FROM configured_domain_verifications
WHERE FALSE;

ROLLBACK;
