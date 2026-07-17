-- Deploy garnix:add-build-status-skipped to pg

-- A run/build can now conclude 'skipped' (GitHub's `skipped` conclusion,
-- treated as success for dependent checks). FOD checks use it when nothing
-- could be re-verified but nothing failed either. NOT wrapped in a
-- transaction: Postgres forbids using a freshly-added enum value in the same
-- transaction that adds it.
ALTER TYPE build_status ADD VALUE IF NOT EXISTS 'skipped';
