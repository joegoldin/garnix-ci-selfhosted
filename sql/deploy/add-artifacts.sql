-- Deploy garnix:add-artifacts to pg

BEGIN;

CREATE TABLE artifact_objects (
  store_hash text NOT NULL,
  bucket     text NOT NULL,
  total_size bigint NOT NULL,
  file_count int NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_hash, bucket)
);

CREATE TABLE artifacts (
  id          bigserial PRIMARY KEY,
  build_id    bigint NOT NULL REFERENCES builds(id),
  repo_user   text NOT NULL,
  repo_name   text NOT NULL,
  branch      text,
  name        text NOT NULL,
  store_hash  text NOT NULL,
  bucket      text NOT NULL,
  status      text NOT NULL,
  locked      boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (build_id, name)
);
CREATE INDEX artifacts_repo_branch_name_idx ON artifacts (repo_user, repo_name, branch, name, created_at DESC);

ALTER TABLE server_settings
  ADD COLUMN artifact_retention_days int NOT NULL DEFAULT 30,
  ADD COLUMN artifact_keep_latest boolean NOT NULL DEFAULT false;

ALTER TABLE repo_config
  ADD COLUMN artifact_retention_days int,
  ADD COLUMN artifact_keep_latest boolean;

COMMIT;
