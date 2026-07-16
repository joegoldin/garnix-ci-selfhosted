-- Deploy garnix:drop-billing-and-plans to pg
-- This is a self-hosting-only fork: there is no billing and there are no
-- product-plan limits, so drop the now-unused plan/entitlement tables and the
-- Stripe columns. Usage tracking (the builds table) is unaffected. Idempotent.

BEGIN;

DROP TABLE IF EXISTS repo_owner_has_product;
DROP TABLE IF EXISTS repo_owner_usage_limits;
DROP TABLE IF EXISTS products;

ALTER TABLE installations
  DROP COLUMN IF EXISTS stripe_customer,
  DROP COLUMN IF EXISTS current_period_start,
  DROP COLUMN IF EXISTS current_period_end,
  DROP COLUMN IF EXISTS requested_cancellation;

ALTER TABLE builds
  DROP COLUMN IF EXISTS comped;

COMMIT;
