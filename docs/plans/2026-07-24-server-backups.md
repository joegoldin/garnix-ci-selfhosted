# Server Backups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** First-class scheduled backups of garnix-hosted microVM servers: configured per-server in `garnix.yaml` (`backups:` with paths, schedule, and pre/post hooks for both backup and restore), captured by the backend over SSH, stored in one private B2 bucket, governed by artifacts-style retention on the Configure page, and surfaced on the Servers page with download / restore / back-up-now.

**Architecture:** The backend pulls: a `forkForever` scheduler SSHes into live guests with the existing hosting key (`ServerPool.sshArgsFor`, exactly like `captureAndStoreSshUsers`), runs the pre-hook, streams `sudo tar` to a local spool, runs the post-hook, compresses with `zstd`, content-addresses with `nix-hash` (base32 sha256), and uploads via a new single-bucket `BackupStore`. Rows live in new `backups` / `backup_objects` / `backup_restores` tables that **outlive the server row** (`ON DELETE SET NULL` + denormalized repo identity). Retention mirrors the artifacts reaper CTE with keep-latest defaulting **on**. Restore reverses the pipeline (download → decompress backend-side → stream plain tar into the guest over SSH stdin), wrapped in the restore hooks.

**Tech Stack:** Haskell (Servant, postgresql-typed `pgSQL`, amazonka, autodocodec, cradle `runSubProcess`), sqitch SQL migrations, Next.js + zod frontend, NixOS module, agenix secrets on the erdtree host.

**Spec:** `docs/plans/2026-07-20-server-backups-design.md` (committed, unchanged). Where this plan and the spec disagree on a detail, this plan wins (it was written against HEAD `1bd5101`, 85 commits later).

## Global Constraints

- Work directly on branch `main` of `~/Development/garnix-ci` (fork convention — no feature branches).
- **`git add` every NEW file immediately** — a git-repo flake excludes untracked files, so `nix build` fails with "can't find source" otherwise. Modified tracked files need no staging to build.
- Do NOT touch these pre-existing untracked/dirty files: `docs/handoffs/`, `docs/plans/2026-07-20-garnix-hosting-hardening.md`, `provisioner/test_provisionerd_ports.py`, `provisioner/default.nix` (dirty), `backend/cabal.project.local~`, `__pycache__` dirs.
- Bare `cabal build` FAILS (`postgresql-typed` connects to live Postgres at compile time). Use the dev-shell loop below for iteration, and `nix build` as the authoritative gate. Never pipe `nix build` through `tail`/`head` — it masks the exit code. On failure: `nix log /nix/store/<hash>-garnix-0.1.0.0.drv`.
- Dev-shell compile+test loop (run from repo root; each run gets a throwaway DB):

  ```bash
  nix develop --command bash -c '
    set -e
    DB_DIR=$(mktemp -d /tmp/specdb.XXXXXX)
    export DB_DIR PGDATA=$DB_DIR/test PGHOST=$DB_DIR/test \
           TPG_HOST=$DB_DIR/test TPG_SOCK=$DB_DIR/test/.s.PGSQL.9178
    db new
    cd backend
    cabal build lib:garnix                      # or: cabal run spec -- --match "<substring>"
    db clear; rm -rf $DB_DIR'
  ```

  `db new` applies ALL sql/deploy migrations to the throwaway DB — so the Task 1 migration must land before any Haskell that queries the new tables will typecheck.
- Every new Haskell module goes in `backend/garnix.cabal` **twice**: library `exposed-modules` (alphabetical) AND the `test-suite spec` re-list of library modules; every new spec file goes in the `test-suite spec` `other-modules` (alphabetical). hspec-discover finds specs automatically but the cabal lists are still required.
- Test conventions: `describe "..." $ inM $ beforeM_ truncateDBM $ do ...`; handlers are called directly (not over HTTP); tests needing a real qemu guest go under a `describe` label containing `@slow`. There is NO `@skip-ci` tag in this repo.
- snake_case JSON via `ourToJSON`/`ourToEncoding`/`ourParseJSON` on all DTOs.
- Commit after every task with the message given in the task. Do not push until Task 14 says so.
- The two final infra tasks are OPERATOR CHECKPOINTS: print the instructions, STOP, and wait for Joe.

## File Structure (what gets created/modified)

```
CREATE  sql/deploy/add-backups.sql            migration: 3 tables + retention columns + servers.backups
CREATE  sql/revert/add-backups.sql            revert file (recent-migration convention)
MODIFY  sql/sqitch.plan                       one appended line
MODIFY  backend/src/Garnix/YamlConfig.hs      BackupSchedule + BackupSection + ServerSection field
MODIFY  backend/src/Garnix/Monad.hs           BackupStore record + Env.backupStore
CREATE  backend/src/Garnix/Backups/Store.hs   s3BackupStore (single private bucket)
CREATE  backend/src/Garnix/DB/Backups.hs      all backup queries
CREATE  backend/src/Garnix/Backups.hs         capture + restore pipelines
CREATE  backend/src/Garnix/Backups/Scheduler.hs   due-check loop
CREATE  backend/src/Garnix/Backups/Reaper.hs  retention + object GC + stale-running sweep
CREATE  backend/src/Garnix/API/Backups.hs     BackupsAPI
MODIFY  backend/src/Garnix.hs                 env wiring + startup threads
MODIFY  backend/src/Garnix/API.hs             mount
MODIFY  backend/src/Garnix/API/Configure.hs   retention DTOs/routes/handlers
MODIFY  backend/src/Garnix/Types.hs           ServerToSpinUp.backups
MODIFY  backend/src/Garnix/Hosting/Deploy.hs  thread backups jsonb; call setServerBackups
MODIFY  backend/src/Garnix/DB.hs              setServerBackups
MODIFY  backend/src/Garnix/S3Cache.hs         export getFileHash
MODIFY  backend/nixos-module.nix              s3Backups + maxBackupSize options, env, zstd in path
MODIFY  backend/garnix.cabal                  module registration
CREATE  backend/test/spec/Garnix/DB/BackupsSpec.hs
CREATE  backend/test/spec/Garnix/Backups/SchedulerSpec.hs
CREATE  backend/test/spec/Garnix/API/BackupsSpec.hs
MODIFY  backend/test/spec/Garnix/YamlConfigSpec.hs
MODIFY  backend/test/spec/Garnix/TestHelpers/Monad.hs   backupStore = Nothing
CREATE  frontend/src/services/backups.ts
MODIFY  frontend/src/services/configure.ts
MODIFY  frontend/src/app/servers/page.tsx     Backups button + BackupsModal
MODIFY  frontend/src/app/configure/page.tsx   BackupSettings section
CREATE  frontend/src/components/icons/backup.tsx
MODIFY  README.md                             feature section
(dotfiles repo, operator tasks)               agenix secrets, s3Backups option, Caddy bypass
```

---

### Task 1: SQL migration

**Files:**
- Create: `sql/deploy/add-backups.sql`
- Create: `sql/revert/add-backups.sql`
- Modify: `sql/sqitch.plan` (append one line at end)

**Interfaces:**
- Produces: tables `backups`, `backup_objects`, `backup_restores`; columns `server_settings.backup_retention_days` (int, default 30), `server_settings.backup_keep_latest` (bool, default **true**), `repo_config.backup_retention_days` (nullable), `repo_config.backup_keep_latest` (nullable), `servers.backups` (nullable jsonb). Every later DB task assumes exactly these names.

- [ ] **Step 1: Write the deploy migration**

`sql/deploy/add-backups.sql`:

```sql
-- Deploy garnix:add-backups to pg
-- Scheduled server backups: snapshot rows (which deliberately OUTLIVE their
-- server via ON DELETE SET NULL + denormalized repo identity — restoring
-- after accidental server deletion is the point), content-addressed object
-- bookkeeping, restore audit rows, artifacts-style retention settings
-- (keep-latest defaults ON: retention must never delete the last snapshot),
-- and the per-server backup config captured at deploy time. Idempotent.

BEGIN;

CREATE TABLE IF NOT EXISTS backup_objects (
  object_hash text PRIMARY KEY,   -- nix-hash --base32 sha256 of the .tar.zst
  total_size  bigint NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS backups (
  id               bigserial PRIMARY KEY,
  server_id        bigint REFERENCES servers(id) ON DELETE SET NULL,
  repo_user        text NOT NULL,
  repo_name        text NOT NULL,
  branch           text,
  configuration    text NOT NULL,               -- builds.package of the deployed config
  persistence_name text,
  object_hash      text REFERENCES backup_objects(object_hash),
  status           text NOT NULL,               -- running | success | failed
  error            text,
  kind             text NOT NULL DEFAULT 'scheduled',  -- scheduled | manual
  locked           boolean NOT NULL DEFAULT false,
  size             bigint,
  started_at       timestamptz NOT NULL DEFAULT now(),
  finished_at      timestamptz
);
CREATE INDEX IF NOT EXISTS backups_repo_config_idx
  ON backups (repo_user, repo_name, configuration, started_at DESC);
CREATE INDEX IF NOT EXISTS backups_server_idx ON backups (server_id);

CREATE TABLE IF NOT EXISTS backup_restores (
  id           bigserial PRIMARY KEY,
  backup_id    bigint NOT NULL REFERENCES backups(id),
  server_id    bigint REFERENCES servers(id) ON DELETE SET NULL,
  status       text NOT NULL,                   -- running | success | failed
  error        text,
  initiated_by text NOT NULL,
  started_at   timestamptz NOT NULL DEFAULT now(),
  finished_at  timestamptz
);

ALTER TABLE server_settings
  ADD COLUMN IF NOT EXISTS backup_retention_days int NOT NULL DEFAULT 30,
  ADD COLUMN IF NOT EXISTS backup_keep_latest boolean NOT NULL DEFAULT true;

ALTER TABLE repo_config
  ADD COLUMN IF NOT EXISTS backup_retention_days int,
  ADD COLUMN IF NOT EXISTS backup_keep_latest boolean;

ALTER TABLE servers
  ADD COLUMN IF NOT EXISTS backups jsonb;

COMMIT;
```

- [ ] **Step 2: Write the revert migration**

`sql/revert/add-backups.sql`:

```sql
-- Revert garnix:add-backups from pg

BEGIN;

ALTER TABLE servers DROP COLUMN IF EXISTS backups;
ALTER TABLE repo_config
  DROP COLUMN IF EXISTS backup_retention_days,
  DROP COLUMN IF EXISTS backup_keep_latest;
ALTER TABLE server_settings
  DROP COLUMN IF EXISTS backup_retention_days,
  DROP COLUMN IF EXISTS backup_keep_latest;
DROP TABLE IF EXISTS backup_restores;
DROP TABLE IF EXISTS backups;
DROP TABLE IF EXISTS backup_objects;

COMMIT;
```

- [ ] **Step 3: Register in sqitch.plan**

Append to `sql/sqitch.plan` (last line of the file; keep the exact format of the surrounding lines):

```
add-backups [add-artifacts] 2026-07-24T21:30:00Z joegoldin <joe@joegold.in> # Scheduled server backups: snapshot/object/restore tables, retention settings, per-server backup config
```

- [ ] **Step 4: Verify the migration applies**

```bash
cd ~/Development/garnix-ci
nix develop --command bash -c '
  set -e
  DB_DIR=$(mktemp -d /tmp/specdb.XXXXXX)
  export DB_DIR PGDATA=$DB_DIR/test PGHOST=$DB_DIR/test \
         TPG_HOST=$DB_DIR/test TPG_SOCK=$DB_DIR/test/.s.PGSQL.9178
  db new
  psql -h $DB_DIR/test -p 9178 -U garnix -d garnix -c "\d backups" -c "\d backup_objects" -c "\d backup_restores"
  db clear; rm -rf $DB_DIR'
```

Expected: three table descriptions print; `backups` shows `server_id … references servers(id) ON DELETE SET NULL` and `servers` gains `backups jsonb` (check with `-c "\d servers"` if in doubt). If `db new` errors, read the SQL error — it aborts on the first broken statement.

- [ ] **Step 5: Commit**

```bash
git add sql/deploy/add-backups.sql sql/revert/add-backups.sql sql/sqitch.plan
git commit -m "sql: add-backups migration (backups/backup_objects/backup_restores, retention settings, servers.backups)"
```

---

### Task 2: `garnix.yaml` — `BackupSchedule`, `BackupSection`, `ServerSection.backups`

**Files:**
- Modify: `backend/src/Garnix/YamlConfig.hs`
- Test: `backend/test/spec/Garnix/YamlConfigSpec.hs`

**Interfaces:**
- Produces: `data BackupSchedule = BackupSchedule { _backupScheduleRaw :: Text, _backupScheduleHours :: Int }`; `data BackupSection` with fields `_backupSectionPaths :: [Text]`, `_backupSectionSchedule :: BackupSchedule`, `_backupSectionPreBackupCommand, _backupSectionPostBackupCommand, _backupSectionPreRestoreCommand, _backupSectionPostRestoreCommand :: Maybe Text`; JSON instances via `Autodocodec` deriving-via (used by the `servers.backups` jsonb round-trip); `ServerSection` gains `_serverSectionBackups :: Maybe BackupSection` with lens `backups`. Later tasks import `BackupSection (..), BackupSchedule (..)` from `Garnix.YamlConfig`.

- [ ] **Step 1: Write the failing tests**

In `backend/test/spec/Garnix/YamlConfigSpec.hs`, inside the top-level `describe` for config parsing (append a new `describe` block at the same indentation as existing ones; find them with `grep -n "describe" backend/test/spec/Garnix/YamlConfigSpec.hs`). Follow the file's existing idiom for parsing a yaml string (look at how existing cases decode a config — reuse the same helper the file already uses, e.g. an `eitherDecode`/`parseYaml` helper; do NOT invent a new one):

```haskell
  describe "servers[].backups" $ do
    it "parses a full backups section" $ do
      -- reuse the file's existing yaml-parse helper on:
      -- servers:
      --   - configuration: fridge
      --     deployment: { type: on-branch, branch: main }
      --     backups:
      --       paths: [ /var/lib/app ]
      --       schedule: daily
      --       preBackupCommand: "echo pre"
      --       postRestoreCommand: "echo post"
      -- and assert:
      --   _serverSectionBackups is Just
      --   _backupSectionPaths == ["/var/lib/app"]
      --   _backupScheduleHours (_backupSectionSchedule …) == 24
      --   _backupSectionPreBackupCommand == Just "echo pre"
      --   _backupSectionPostBackupCommand == Nothing

    it "defaults schedule to daily" $ do
      -- backups: { paths: [ /var/lib/app ] }  →  _backupScheduleHours == 24

    it "parses interval schedules" $ do
      -- schedule: "6h" → hours == 6 ; "hourly" → 1 ; "weekly" → 168

    it "rejects bad schedules" $ do
      -- schedule: "0h" and schedule: "sometimes" → parse failure

    it "rejects bad paths" $ do
      -- paths: [ relative/path ] → failure
      -- paths: [ / ] → failure
      -- paths: [ /nix/store/foo ] → failure
      -- paths: [] → failure
```

Write these as real test cases using the file's existing helpers (the comments above are the required inputs/assertions, not placeholders to leave in).

- [ ] **Step 2: Run the tests to verify they fail**

Use the dev-shell loop from Global Constraints with `cabal run spec -- --match "servers[].backups"`.
Expected: compile failure (`BackupSection` not in scope) — that counts as the failing state.

- [ ] **Step 3: Implement in YamlConfig.hs**

Add near `ServerLogFile` (its `bimapCodec` validation at the `instance HasCodec ServerLogFile` is the pattern; find with `grep -n "ServerLogFile" backend/src/Garnix/YamlConfig.hs`):

```haskell
-- | How often a server is backed up. Keeps the raw text the user wrote (for
-- faithful re-encoding) plus the resolved interval in hours.
data BackupSchedule = BackupSchedule
  { _backupScheduleRaw :: Text,
    _backupScheduleHours :: Int
  }
  deriving stock (Eq, Show, Generic)

parseBackupSchedule :: Text -> Either String BackupSchedule
parseBackupSchedule raw = case raw of
  "hourly" -> Right $ BackupSchedule raw 1
  "daily" -> Right $ BackupSchedule raw 24
  "weekly" -> Right $ BackupSchedule raw (24 * 7)
  _ -> case T.stripSuffix "h" raw of
    Just n | Just hours <- readMaybe (cs n), hours >= 1 -> Right $ BackupSchedule raw hours
    _ -> Left $ "backups.schedule must be hourly|daily|weekly or \"<N>h\" (N >= 1), got: " <> cs raw

instance HasCodec BackupSchedule where
  codec = bimapCodec parseBackupSchedule _backupScheduleRaw textCodec

validateBackupPath :: Text -> Either String Text
validateBackupPath path
  | not (isAbsolute (cs path)) = Left $ "backups.paths entries must be absolute paths, got: " <> cs path
  | path == "/" = Left "backups.paths must not contain /"
  | "/nix/store" `T.isPrefixOf` path = Left "backups.paths must not contain /nix/store paths"
  | ".." `elem` splitDirectories (cs path) = Left "backups.paths must not contain '..' components"
  | T.any (`elem` ['\NUL', '\n', '\r', '\'']) path = Left "backups.paths must not contain NUL, newline, or single-quote characters"
  | otherwise = Right path

validateBackupPaths :: [Text] -> Either String [Text]
validateBackupPaths [] = Left "backups.paths must not be empty"
validateBackupPaths paths = traverse validateBackupPath paths

data BackupSection = BackupSection
  { _backupSectionPaths :: [Text],
    _backupSectionSchedule :: BackupSchedule,
    _backupSectionPreBackupCommand :: Maybe Text,
    _backupSectionPostBackupCommand :: Maybe Text,
    _backupSectionPreRestoreCommand :: Maybe Text,
    _backupSectionPostRestoreCommand :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving (Aeson.FromJSON, Aeson.ToJSON) via (Autodocodec BackupSection)

instance HasCodec BackupSection where
  codec =
    object "backups"
      $ BackupSection
      <$> requiredFieldWith
        "paths"
        (bimapCodec validateBackupPaths Prelude.id codec)
        "Absolute paths inside the server to back up. Must not be empty, /, or under /nix/store."
      .= _backupSectionPaths
      <*> optionalFieldWithDefault
        "schedule"
        (BackupSchedule "daily" 24)
        "How often to back up: hourly | daily (default) | weekly | \"<N>h\"."
      .= _backupSectionSchedule
      <*> optionalField
        "preBackupCommand"
        "Command run on the server (as root, via sh -c) before the backup tar is taken. A non-zero exit aborts the backup."
      .= _backupSectionPreBackupCommand
      <*> optionalField
        "postBackupCommand"
        "Command run on the server after the tar is taken (cleanup). Always attempted, even if the tar failed."
      .= _backupSectionPostBackupCommand
      <*> optionalField
        "preRestoreCommand"
        "Command run on the server before a restore untars (e.g. stop your service)."
      .= _backupSectionPreRestoreCommand
      <*> optionalField
        "postRestoreCommand"
        "Command run on the server after a restore untars (e.g. start your service). Always attempted, even if the untar failed."
      .= _backupSectionPostRestoreCommand
```

Notes for this step (all resolvable by grep in this one file):
- Import list: the module already imports `Data.Text qualified as T`, `readMaybe`, `isAbsolute`/`splitDirectories` (used by `ServerLogFile`) and `Autodocodec` codecs. If `Autodocodec (..)` deriving-via newtype or `Aeson` are not yet imported, add `import Autodocodec (Autodocodec (..))` and `import Data.Aeson qualified as Aeson` next to the existing imports. If `requiredFieldWith` is not already imported from autodocodec, add it where `requiredField` comes from.
- Add `_serverSectionBackups :: Maybe BackupSection` as the LAST field of `ServerSection` (after `_serverSectionLogFile`), and in the `HasCodec ServerSection` instance append, after the `applicationLog` field codec:

```haskell
      <*> optionalField
        "backups"
        "Scheduled backups of paths on this server: garnix SSHes in on the schedule, tars the paths, and stores the snapshot in the operator's backup bucket. See also preBackupCommand/preRestoreCommand hooks."
      .= _serverSectionBackups
```

- At the bottom of the file add `makeFields ''BackupSection` and `makeFields ''BackupSchedule` next to the existing `makeFields ''ServerSection` line (order matters: `makeFields ''BackupSection` must come before... actually TH splices only need the type defined above them; put both right after `makeFields ''ServerSection`).
- Export from the module header list: `BackupSection (..)`, `BackupSchedule (..)`, `parseBackupSchedule`, `validateBackupPaths`, and the generated lenses `backups` (the export list already names lenses like `domains`, `logFile` — add `backups` beside them).

- [ ] **Step 4: Run the tests to verify they pass**

Dev-shell loop, `cabal run spec -- --match "servers[].backups"`.
Expected: all cases PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/src/Garnix/YamlConfig.hs backend/test/spec/Garnix/YamlConfigSpec.hs
git commit -m "feat(yaml): servers[].backups section (paths, schedule, backup/restore hooks)"
```

---

### Task 3: `BackupStore` type, `Env.backupStore`, test-env default

**Files:**
- Modify: `backend/src/Garnix/Monad.hs`
- Modify: `backend/test/spec/Garnix/TestHelpers/Monad.hs`

**Interfaces:**
- Produces (all from `Garnix.Monad`, which everything already imports):

```haskell
data BackupStore = BackupStore
  { _backupStorePutFile :: Text -> FilePath -> M (),   -- key, local file
    _backupStoreGetFile :: Text -> FilePath -> M (),   -- key, local target file
    _backupStoreDeleteObject :: Text -> M (),
    _backupStorePresignGet :: Text -> M Text,          -- 10-minute URL
    _backupStoreMaxSize :: Integer                     -- compressed-size cap in bytes
  }
  deriving (Generic)
```

  and Env field `backupStore :: Maybe BackupStore` (accessed as `view #backupStore`).

- [ ] **Step 1: Add the type + Env field**

In `backend/src/Garnix/Monad.hs`:

1. Directly under the `ArtifactStore` record definition (find with `grep -n "data ArtifactStore" backend/src/Garnix/Monad.hs`), add the `BackupStore` record exactly as in Interfaces above, with this haddock:

```haskell
-- | Storage operations for server backups (garnix.yaml @servers[].backups:@),
-- as a record of functions so tests can plug in an in-memory implementation.
-- Single private bucket — backups are always sensitive, there is no public
-- variant. Production impl: "Garnix.Backups.Store".
```

2. In the `Env` record, insert directly after the `artifactStore :: Maybe ArtifactStore,` line (anchor: `grep -n "artifactStore :: Maybe ArtifactStore" backend/src/Garnix/Monad.hs`):

```haskell
    -- | Storage backend for server backups (garnix.yaml @servers[].backups:@).
    -- 'Nothing' when S3_BACKUPS_BUCKET is not configured, which disables the
    -- feature (API 404s, no scheduler).
    backupStore :: Maybe BackupStore,
```

3. Export `BackupStore (..)` from the module export list next to `ArtifactStore (..)` (grep the export list for `ArtifactStore`).

- [ ] **Step 2: Fix the test Env**

In `backend/test/spec/Garnix/TestHelpers/Monad.hs`, directly after the `artifactStore = Nothing,` line (anchor: `grep -n "artifactStore = Nothing" backend/test/spec/Garnix/TestHelpers/Monad.hs`):

```haskell
                  backupStore = Nothing,
```

- [ ] **Step 3: Compile**

Dev-shell loop with `cabal build lib:garnix`. Expected: compiles. (The Env is also constructed in `backend/src/Garnix.hs` — that construction now fails with a missing-field warning/error; if it errors here, add `backupStore = Nothing,` there temporarily — Task 5 replaces it with the real wiring. Check with `grep -n "artifactStore," backend/src/Garnix.hs` and mirror.)

- [ ] **Step 4: Commit**

```bash
git add backend/src/Garnix/Monad.hs backend/test/spec/Garnix/TestHelpers/Monad.hs backend/src/Garnix.hs
git commit -m "feat(backups): BackupStore record + Env.backupStore (feature-gated, off by default)"
```

---

### Task 4: `Garnix.Backups.Store` — the S3 implementation

**Files:**
- Create: `backend/src/Garnix/Backups/Store.hs`
- Modify: `backend/garnix.cabal` (register module; see Global Constraints — both lists)

**Interfaces:**
- Consumes: `BackupStore` from Task 3.
- Produces: `s3BackupStore :: Amazonka.Env -> Amazonka.BucketName -> Integer -> BackupStore` (env, bucket, maxSize).

- [ ] **Step 1: Write the module**

`backend/src/Garnix/Backups/Store.hs` — full contents (modeled 1:1 on `Garnix/Artifacts/Store.hs`, single-bucket; read that file first and keep the same `send` helper shape):

```haskell
-- | The amazonka-backed production implementation of 'BackupStore'.
--
-- One private bucket with its own single-bucket credential pair (B2
-- application keys are single-bucket). Downloads are served via short-lived
-- presigned GET URLs only — server backups are always sensitive, so unlike
-- artifacts there is no public bucket and no stable public URL.
module Garnix.Backups.Store (s3BackupStore) where

import Amazonka qualified
import Amazonka.S3 qualified as Amazonka
import Conduit (sinkFile)
import Garnix.Duration
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types

s3BackupStore :: Amazonka.Env -> Amazonka.BucketName -> Integer -> BackupStore
s3BackupStore env bucket maxSize =
  BackupStore
    { _backupStorePutFile = putFile,
      _backupStoreGetFile = getFile,
      _backupStoreDeleteObject = deleteObject,
      _backupStorePresignGet = presignGet,
      _backupStoreMaxSize = maxSize
    }
  where
    putFile :: Text -> FilePath -> M ()
    putFile key path = do
      body <- Amazonka.toBody <$> Amazonka.hashedFile path
      void
        $ send env
        $ Amazonka.newPutObject bucket (Amazonka.ObjectKey key) body

    getFile :: Text -> FilePath -> M ()
    getFile key path = do
      response <-
        liftIO
          $ runResourceT
          $ Amazonka.sendEither env (Amazonka.newGetObject bucket (Amazonka.ObjectKey key))
      case response of
        Left err -> throw $ OtherError $ show err
        Right ok ->
          liftIO
            $ runResourceT
            $ Amazonka.sinkBody (ok ^. #body) (sinkFile path)

    deleteObject :: Text -> M ()
    deleteObject key =
      void
        $ send env
        $ Amazonka.newDeleteObject bucket (Amazonka.ObjectKey key)

    presignGet :: Text -> M Text
    presignGet key = do
      now <- liftIO getCurrentTime
      cs
        <$> Amazonka.presignURL
          env
          now
          (toAmazonkaSeconds (fromMinutes @Int 10))
          (Amazonka.newGetObject bucket (Amazonka.ObjectKey key))

toAmazonkaSeconds :: Duration -> Amazonka.Seconds
toAmazonkaSeconds = Amazonka.Seconds . realToFrac . toSeconds

send ::
  (Amazonka.AWSRequest request, Typeable request, Typeable (Amazonka.AWSResponse request)) =>
  Amazonka.Env ->
  request ->
  M (Amazonka.AWSResponse request)
send env request = do
  response <-
    liftIO
      $ runResourceT
      $ Amazonka.sendEither env request
  case response of
    Left error -> throw $ OtherError $ show error
    Right response -> pure response
```

Import fixes you may need (resolve by copying whatever `Garnix/Artifacts/Store.hs` imports for the same symbols): `runResourceT`, `getCurrentTime`. For `sinkFile`: if `Conduit` is not an available package, use `import Data.Conduit.Binary (sinkFile)` (package `conduit-extra`). Check `grep -n "conduit" backend/garnix.cabal`; if neither `conduit` nor `conduit-extra` is in `build-depends`, add `conduit-extra` on its own line in the library `build-depends` list (alphabetical). `Amazonka.sinkBody` is from the `amazonka` core package already in use.

- [ ] **Step 2: Register in garnix.cabal**

Insert `Garnix.Backups.Store` into BOTH module lists (see Global Constraints). Library `exposed-modules`: between `Garnix.Attribute` and `Garnix.Build` (alongside the future `Garnix.Backups`, `Garnix.Backups.Reaper`, `Garnix.Backups.Scheduler` — you can add all four lines now to avoid re-touching):

```
      Garnix.Backups
      Garnix.Backups.Reaper
      Garnix.Backups.Scheduler
      Garnix.Backups.Store
```

(Adding all four now means the build fails until those modules exist — so EITHER add only `Garnix.Backups.Store` now and the rest in their tasks, OR create empty stub modules. Add only `Garnix.Backups.Store` now; add each other line in its own task.)

- [ ] **Step 3: Compile**

Dev-shell `cabal build lib:garnix`. Expected: compiles.

- [ ] **Step 4: Commit**

```bash
git add backend/src/Garnix/Backups/Store.hs backend/garnix.cabal
git commit -m "feat(backups): s3BackupStore — single private bucket, streaming get/put, presigned downloads"
```

---

### Task 5: Env wiring in `Garnix.hs`

**Files:**
- Modify: `backend/src/Garnix.hs`

**Interfaces:**
- Consumes: `s3BackupStore` (Task 4).
- Produces: env vars `S3_BACKUPS_BUCKET`, `GARNIX_MAX_BACKUP_SIZE` (bytes, default 4 GiB), secrets `/run/secrets/s3-backups-access-key-id` + `/run/secrets/s3-backups-secret-access-key` (or env-var overrides `S3_BACKUPS_ACCESS_KEY_ID`/`S3_BACKUPS_SECRET_ACCESS_KEY`); `Env.backupStore` populated.

- [ ] **Step 1: Add the wiring**

In `backend/src/Garnix.hs`, directly after the artifacts wiring block (anchor: `grep -n "S3_ARTIFACTS_PUBLIC_BUCKET" backend/src/Garnix.hs`, the block ends with `_ -> pure Nothing`):

```haskell
  -- Server backups (optional feature): one private bucket with its own
  -- single-bucket credential pair. Never public — no base URL.
  backupsBucket <- lookupEnv "S3_BACKUPS_BUCKET"
  maxBackupSize <-
    lookupEnv "GARNIX_MAX_BACKUP_SIZE" >>= \case
      Just s | Just n <- readMaybe s, n > 0 -> pure n
      _ -> pure (4 * 2 ^ (30 :: Integer))
  backupStore <- case backupsBucket of
    Just bucket -> do
      keyId <- readOptionalSecret "S3_BACKUPS_ACCESS_KEY_ID" "/run/secrets/s3-backups-access-key-id"
      key <- readOptionalSecret "S3_BACKUPS_SECRET_ACCESS_KEY" "/run/secrets/s3-backups-secret-access-key"
      case (keyId, key) of
        (Just a, Just b) -> do
          bEnv <- mkAmazonkaEnv (Amazonka.AccessKey a) (Amazonka.SecretKey b)
          pure $ Just $ s3BackupStore bEnv (Amazonka.BucketName (cs bucket)) maxBackupSize
        _ -> error "S3_BACKUPS_BUCKET is set but its key pair is missing."
    Nothing -> pure Nothing
```

Then:
- Add `import Garnix.Backups.Store (s3BackupStore)` next to `import Garnix.Artifacts.Store (s3ArtifactStore)`.
- In the Env construction (anchor: `grep -n "artifactStore," backend/src/Garnix.hs`), replace the temporary `backupStore = Nothing,` from Task 3 with `backupStore,` on the line after `artifactStore,`.

- [ ] **Step 2: Compile, commit**

Dev-shell `cabal build lib:garnix` → compiles.

```bash
git add backend/src/Garnix.hs
git commit -m "feat(backups): S3_BACKUPS_* env wiring + GARNIX_MAX_BACKUP_SIZE (default 4 GiB)"
```

---

### Task 6: `Garnix.DB.Backups` — the full query layer

**Files:**
- Create: `backend/src/Garnix/DB/Backups.hs`
- Create: `backend/test/spec/Garnix/DB/BackupsSpec.hs`
- Modify: `backend/garnix.cabal` (register `Garnix.DB.Backups` in both lists between `Garnix.DB.Artifacts` and `Garnix.DB.FeatureFlags`; register `Garnix.DB.BackupsSpec` in test-suite `other-modules` between `Garnix.DB.ArtifactsSpec` and `Garnix.DB.FeatureFlagsSpec`)

**Interfaces:**
- Consumes: tables from Task 1; `addTestServer` from `Garnix.TestHelpers` (existing).
- Produces (module `Garnix.DB.Backups`; signatures later tasks call verbatim):

```haskell
data BackupRow = BackupRow
  { _backupRowId :: Int64, _backupRowServerId :: Maybe ServerId,
    _backupRowRepoUser :: GhRepoOwner, _backupRowRepoName :: GhRepoName,
    _backupRowBranch :: Maybe Branch, _backupRowConfiguration :: Text,
    _backupRowPersistenceName :: Maybe Text, _backupRowObjectHash :: Maybe Text,
    _backupRowStatus :: Text, _backupRowError :: Maybe Text, _backupRowKind :: Text,
    _backupRowLocked :: Bool, _backupRowSize :: Maybe Int64,
    _backupRowStartedAt :: UTCTime, _backupRowFinishedAt :: Maybe UTCTime }

insertRunningBackup :: ServerId -> GhRepoOwner -> GhRepoName -> Maybe Branch -> Text -> Maybe Text -> Text -> M Int64
finalizeBackupSuccess :: Int64 -> Text -> Int64 -> M ()      -- id, objectHash, size
finalizeBackupFailure :: Int64 -> Text -> M ()               -- id, error
hasRunningBackup :: ServerId -> M Bool
getBackupRow :: Int64 -> M (Maybe BackupRow)
getBackupsForRepo :: GhRepoOwner -> GhRepoName -> M [BackupRow]
getBackupsForServerConfig :: GhRepoOwner -> GhRepoName -> Text -> M [BackupRow]  -- incl. prior incarnations
getLatestSuccessfulBackup :: GhRepoOwner -> GhRepoName -> Text -> M (Maybe BackupRow)
setBackupLocked :: Int64 -> Bool -> M ()
deleteBackupRow :: Int64 -> M ()
upsertBackupObject :: Text -> Int64 -> M ()                  -- hash, size; ON CONFLICT DO NOTHING
backupObjectExists :: Text -> M Bool
getOrphanedBackupObjects :: M [Text]
deleteBackupObject :: Text -> M ()
reapExpiredBackupRows :: M Int64
pruneFailedBackupRows :: M Int64
failStaleRunningBackups :: M Int64                           -- running > 2h -> failed 'orphaned by restart or crash'
getLiveBackupTargets :: M [(ServerId, Text, GhRepoOwner, GhRepoName, Maybe Branch, Text, Maybe Text, Text, Maybe UTCTime)]
  -- (serverId, ipv4, owner, repo, branch, configuration=builds.package, persistenceName, backupsJsonText, lastSuccessStartedAt)
getBackupSettings :: M (Int32, Bool)
setDefaultBackupSettings :: Int32 -> Bool -> M ()
setRepoBackupSettings :: GhRepoOwner -> GhRepoName -> Maybe Int32 -> Maybe Bool -> M ()
deleteRepoBackupSettings :: GhRepoOwner -> GhRepoName -> M ()
getBackupRepoOverrides :: M [(GhRepoOwner, GhRepoName, Maybe Int32, Maybe Bool)]
getBackupStorageUsage :: M [(GhRepoOwner, GhRepoName, Int64)]
getLockedBackups :: M [BackupRow]
insertRunningRestore :: Int64 -> ServerId -> Text -> M Int64  -- backupId, serverId, initiatedBy
finalizeRestoreSuccess :: Int64 -> M ()
finalizeRestoreFailure :: Int64 -> Text -> M ()
getRestoresForServerConfig :: GhRepoOwner -> GhRepoName -> Text -> M [(Int64, Int64, Text, Maybe Text, Text, UTCTime, Maybe UTCTime)]
setServerBackups :: ServerId -> Maybe BackupSection -> M ()
getServerBackups :: ServerId -> M (Maybe BackupSection)
```

- [ ] **Step 1: Write failing tests**

`backend/test/spec/Garnix/DB/BackupsSpec.hs`. Open `backend/test/spec/Garnix/DB/ArtifactsSpec.hs` FIRST and copy its module header, imports, and `describe … $ inM $ beforeM_ truncateDBM $ do` scaffold exactly, then write these cases (real code, using `addTestServer` from `Garnix.TestHelpers` — see its signature in `backend/test/spec/Garnix/TestHelpers.hs`, it takes an `ServerInfo -> ServerInfo` modifier):

```haskell
    it "insert + finalize success round-trips" $ do
      server <- addTestServer (\s -> s & readyAt ?~ someTime)
      bid <- insertRunningBackup (server ^. id) "o" "r" (Just "main") "nixosConfigurations.app" (Just "app") "manual"
      upsertBackupObject "hash1" 123
      finalizeBackupSuccess bid "hash1" 123
      Just row <- getBackupRow bid
      _backupRowStatus row `shouldBeM` "success"
      _backupRowObjectHash row `shouldBeM` Just "hash1"

    it "backup rows survive server deletion (server_id nulls out)" $ do
      -- addTestServer, insertRunningBackup, finalize; then delete the servers
      -- row directly with pgExec DELETE FROM servers WHERE id = ...;
      -- getBackupRow still returns the row, _backupRowServerId == Nothing.

    it "hasRunningBackup sees running rows only" $ do ...

    it "reaper honors retention, keep-latest default ON, and locks" $ do
      -- setDefaultBackupSettings 0 True (retention 0 days = everything expired)
      -- three successful backups for the same (o, r, config), one locked
      -- reapExpiredBackupRows
      -- remaining rows: the newest (keep-latest) AND the locked one
      -- then setDefaultBackupSettings 0 False; reap again; only locked remains

    it "per-repo override beats the default" $ do
      -- default retention 0/keep-latest False; setRepoBackupSettings "o" "r" (Just 3650) Nothing
      -- a fresh backup for o/r survives reap; one for other/repo does not

    it "getOrphanedBackupObjects finds unreferenced objects only" $ do ...

    it "failStaleRunningBackups only touches rows older than 2h" $ do
      -- insertRunningBackup, then UPDATE backups SET started_at = now() - interval '3 hours'
      -- failStaleRunningBackups == 1; a fresh running row stays running

    it "getLiveBackupTargets returns live servers with backups config and last success" $ do
      -- addTestServer with readyAt set; setServerBackups with a BackupSection
      -- (import from Garnix.YamlConfig; construct with BackupSchedule "daily" 24);
      -- target appears with the jsonb text; after finalizeBackupSuccess the
      -- lastSuccess column is non-Nothing; a server with endedAt set disappears.

    it "setServerBackups/getServerBackups round-trip the section" $ do ...

    it "restore rows insert and finalize" $ do ...
```

(The `...` bodies must be written out fully in the actual file — inputs and `shouldBeM` assertions like the first case. `someTime` = `liftIO getCurrentTime` first.)

- [ ] **Step 2: Run to verify failure**

`cabal run spec -- --match "Garnix.DB.Backups"` in the dev-shell loop. Expected: compile failure (module missing).

- [ ] **Step 3: Write the module**

`backend/src/Garnix/DB/Backups.hs`. Copy the module header/import shape from `backend/src/Garnix/DB/Artifacts.hs` (imports: `Database.PostgreSQL.Typed (pgSQL)`, `Garnix.DB qualified as DB`, `Garnix.Monad`, `Garnix.Prelude`, `Garnix.Types`, plus `Data.Aeson qualified as Aeson` and `Garnix.YamlConfig (BackupSection)`). Every function from the Interfaces block, implemented with `DB.pgQuery`/`DB.pgExec`. The non-obvious ones in full:

```haskell
-- | Delete successful, unlocked backup rows older than the effective
-- retention (per-repo override, else the server default), except — when the
-- effective keep-latest is on (the DEFAULT for backups, unlike artifacts) —
-- the newest successful row per repo/configuration.
reapExpiredBackupRows :: M Int64
reapExpiredBackupRows =
  fmap fromIntegral
    $ DB.pgExec
      [pgSQL|
        WITH s AS (
          SELECT backup_retention_days AS d, backup_keep_latest AS k
          FROM server_settings
          WHERE singleton
        ),
        eff AS (
          SELECT b.id,
                 COALESCE(rc.backup_retention_days, s.d) AS retention,
                 COALESCE(rc.backup_keep_latest, s.k) AS keep_latest,
                 row_number() OVER (
                   PARTITION BY b.repo_user, b.repo_name, b.configuration
                   ORDER BY b.started_at DESC, b.id DESC
                 ) AS rn
          FROM backups b
          CROSS JOIN s
          LEFT JOIN repo_config rc
            ON rc.repo_user = b.repo_user AND rc.repo_name = b.repo_name
          WHERE b.status = 'success' AND NOT b.locked
        )
        DELETE FROM backups b
        USING eff
        WHERE b.id = eff.id
          AND b.started_at < now() - make_interval(days => eff.retention)
          AND NOT (eff.keep_latest AND eff.rn = 1)
      |]

pruneFailedBackupRows :: M Int64
pruneFailedBackupRows =
  fmap fromIntegral
    $ DB.pgExec
      [pgSQL|
        DELETE FROM backups
        WHERE status = 'failed'
          AND started_at < now() - interval '7 days'
      |]

failStaleRunningBackups :: M Int64
failStaleRunningBackups =
  fmap fromIntegral
    $ DB.pgExec
      [pgSQL|
        UPDATE backups
        SET status = 'failed',
            error = 'orphaned by restart or crash',
            finished_at = now()
        WHERE status = 'running'
          AND started_at < now() - interval '2 hours'
      |]

getOrphanedBackupObjects :: M [Text]
getOrphanedBackupObjects =
  DB.pgQuery
    [pgSQL|
      SELECT object_hash
      FROM backup_objects bo
      WHERE NOT EXISTS (
        SELECT 1 FROM backups b WHERE b.object_hash = bo.object_hash
      )
      ORDER BY object_hash
    |]

-- | Live servers (ready, not ended) whose deploy captured a backups config,
-- with the started_at of their configuration's most recent successful backup.
getLiveBackupTargets :: M [(ServerId, Text, GhRepoOwner, GhRepoName, Maybe Branch, Text, Maybe Text, Text, Maybe UTCTime)]
getLiveBackupTargets =
  DB.pgQuery
    [pgSQL|
      SELECT s.id, s.ipv4, b.repo_user, b.repo_name, b.branch, b.package,
             b.persistence_name, s.backups::text,
             ( SELECT max(bk.started_at) FROM backups bk
               WHERE bk.repo_user = b.repo_user AND bk.repo_name = b.repo_name
                 AND bk.configuration = b.package AND bk.status = 'success' )
      FROM servers s
      JOIN builds b ON b.id = s.configuration_build_id
      WHERE s.ready_at IS NOT NULL
        AND s.ended_at IS NULL
        AND s.backups IS NOT NULL
      ORDER BY s.id
    |]

setServerBackups :: ServerId -> Maybe BackupSection -> M ()
setServerBackups serverId section = do
  let encoded = cs . Aeson.encode <$> section :: Maybe Text
  void
    $ DB.pgExec
      [pgSQL|
        UPDATE servers
        SET backups = ${encoded}::text::jsonb
        WHERE id = ${serverId}
      |]

getServerBackups :: ServerId -> M (Maybe BackupSection)
getServerBackups serverId = do
  rows <-
    DB.pgQuery
      [pgSQL|
        SELECT backups::text FROM servers WHERE id = ${serverId}
      |]
  pure $ case rows of
    [Just t] -> Aeson.decode (cs (t :: Text))
    _ -> Nothing
```

The settings functions (`getBackupSettings`/`setDefaultBackupSettings`/`setRepoBackupSettings`/`deleteRepoBackupSettings`/`getBackupRepoOverrides`) are line-for-line copies of their artifact twins in `DB/Artifacts.hs` with `artifact_` → `backup_` column renames — including `getBackupSettings`'s singleton-row INSERT guarantee. `getBackupStorageUsage` mirrors `getArtifactStorageUsage` but joins `backups`→`backup_objects` on `object_hash` (SELECT DISTINCT object_hash per repo, SUM total_size). Insert/select/finalize/list functions are straightforward `pgSQL` statements over the Task 1 columns; `getBackupsForRepo`/`getBackupsForServerConfig`/`getLockedBackups` return `BackupRow` built with a shared row-mapping helper (tuple → `BackupRow`, one place). `ServerId` embeds in `pgSQL` the same way `DB.setServerDomains` does it (look at `grep -n "setServerDomains" backend/src/Garnix/DB.hs` for the exact `${serverId}` usage and copy the type handling).

If `pgSQL` complains about nullable typing on any COALESCE/subquery column, use the `[pgSQL|! … |]` bang form (precedent: `getArtifactDtosForBuild`).

- [ ] **Step 4: Register in cabal, run tests**

Add `Garnix.DB.Backups` (both lists) + `Garnix.DB.BackupsSpec` (test-suite `other-modules`). Then dev-shell `cabal run spec -- --match "Garnix.DB.Backups"`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/src/Garnix/DB/Backups.hs backend/test/spec/Garnix/DB/BackupsSpec.hs backend/garnix.cabal
git commit -m "feat(backups): DB layer — rows outlive servers, keep-latest-on retention CTE, live-target query"
```

---

### Task 7: Thread `backups:` through the deploy pipeline

**Files:**
- Modify: `backend/src/Garnix/Types.hs` (ServerToSpinUp)
- Modify: `backend/src/Garnix/Hosting/Deploy.hs`

**Interfaces:**
- Consumes: `BackupSection` lens `backups` on `ServerSection` (Task 2); `setServerBackups` (Task 6).
- Produces: every deploy (spin-up AND in-place redeploy) persists the server's current `backups:` config to `servers.backups`; servers without the section get `NULL`.

- [ ] **Step 1: Add the field to ServerToSpinUp**

In `backend/src/Garnix/Types.hs`, find `ServerToSpinUp` (`grep -n "data ServerToSpinUp" backend/src/Garnix/Types.hs`). It already carries `domains :: [Text]` and a log-file field. Add, following the existing field style exactly:

```haskell
    backups :: Maybe BackupSection,
```

Add `import Garnix.YamlConfig (BackupSection)` if `Types.hs` doesn't already import it (check what it imports for the log-file/domains types and extend that import line). If this creates an import cycle (Types ← YamlConfig), instead move nothing — check first: `grep -n "import Garnix.Types" backend/src/Garnix/YamlConfig.hs`. If YamlConfig imports Types (likely), you CANNOT import YamlConfig from Types. In that case store the raw JSON instead: field `backups :: Maybe Aeson.Value`, encoded at the Deploy.hs population site with `Aeson.toJSON section`, and `setServerBackups` (Task 6) changes its argument to `Maybe Aeson.Value` with `let encoded = cs . Aeson.encode <$> value :: Maybe Text`. Decide by the grep result and apply consistently — the scheduler (Task 8) decodes the jsonb text into `BackupSection` either way.

- [ ] **Step 2: Populate it in getDeployPlan**

In `backend/src/Garnix/Hosting/Deploy.hs`, find the `ServerToSpinUp {…}` construction (`grep -n "ServerToSpinUp" backend/src/Garnix/Hosting/Deploy.hs`) where `domains = _serverSectionDomains section` (or via lenses) is set, and add the parallel line for `backups` from `_serverSectionBackups section` (applying `Aeson.toJSON <$>` if Step 1 chose the `Aeson.Value` representation).

- [ ] **Step 3: Persist at both deploy paths**

Find the two `DB.setServerDomains` call sites (`grep -n "setServerDomains" backend/src/Garnix/Hosting/Deploy.hs`) — one in the spin-up path, one in the redeploy path. Directly after EACH, add:

```haskell
        DBBackups.setServerBackups (serverInfo ^. id) (wanted ^. #backups)
```

(match the local variable names used at each site — the spin-up site may name it `serverToSpinUp` instead of `wanted`; copy whatever the adjacent `setServerDomains` line uses). Add `import Garnix.DB.Backups qualified as DBBackups` to the import list.

Note: the redeploy path's `wanted` is the NEW build's config — an in-place redeploy that drops/edits the `backups:` section updates `servers.backups` accordingly. That is the intended behavior (scheduler always follows current config).

- [ ] **Step 4: Test via the existing DB spec + compile**

The round-trip is covered by Task 6's `setServerBackups/getServerBackups` test. Here just compile: dev-shell `cabal build lib:garnix`. Expected: compiles. Then run the fast deploy-adjacent specs to catch record-update fallout:

```
cabal run spec -- --match "Deploy" --skip "@slow"
```

Expected: no new failures (compare against a `git stash`-run baseline only if failures appear).

- [ ] **Step 5: Commit**

```bash
git add backend/src/Garnix/Types.hs backend/src/Garnix/Hosting/Deploy.hs
git commit -m "feat(backups): capture servers[].backups at deploy into servers.backups jsonb"
```

---

### Task 8: `Garnix.Backups` — capture pipeline + `Garnix.Backups.Scheduler`

**Files:**
- Create: `backend/src/Garnix/Backups.hs`
- Create: `backend/src/Garnix/Backups/Scheduler.hs`
- Create: `backend/test/spec/Garnix/Backups/SchedulerSpec.hs`
- Modify: `backend/src/Garnix/S3Cache.hs` (export `getFileHash`)
- Modify: `backend/src/Garnix.hs` (launch scheduler)
- Modify: `backend/garnix.cabal` (register all: `Garnix.Backups`, `Garnix.Backups.Scheduler` both lists; `Garnix.Backups.SchedulerSpec` test list)

**Interfaces:**
- Consumes: `BackupStore` (Task 3), `Garnix.DB.Backups` (Task 6), `ServerPool.sshArgsForAddress` (existing), `getFileHash` (existing, newly exported), `NoThrow.forkForever`, `remoteAsRoot`-style sudo (self-contained here).
- Produces:

```haskell
-- Garnix.Backups
data BackupTarget = BackupTarget
  { _backupTargetServerId :: ServerId, _backupTargetIpv4 :: Text,
    _backupTargetRepoUser :: GhRepoOwner, _backupTargetRepoName :: GhRepoName,
    _backupTargetBranch :: Maybe Branch, _backupTargetConfiguration :: Text,
    _backupTargetPersistenceName :: Maybe Text, _backupTargetSection :: BackupSection }
runServerBackup :: BackupStore -> BackupTarget -> Text -> M ()   -- kind: "scheduled"|"manual"
backupObjectKey :: Text -> Text                                   -- hash -> "backups/<hash>.tar.zst"
decodeBackupTargets :: [(ServerId, Text, GhRepoOwner, GhRepoName, Maybe Branch, Text, Maybe Text, Text, Maybe UTCTime)]
                    -> [(BackupTarget, Maybe UTCTime)]            -- drops undecodable jsonb with a log
isDue :: UTCTime -> BackupSection -> Maybe UTCTime -> Bool        -- now, section, lastSuccess
-- Garnix.Backups.Scheduler
initializeBackupScheduler :: M ThreadId
```

- [ ] **Step 1: Export getFileHash**

In `backend/src/Garnix/S3Cache.hs`, add `getFileHash` to the module export list (top of file). Compile-check later.

- [ ] **Step 2: Write failing tests for the pure parts**

`backend/test/spec/Garnix/Backups/SchedulerSpec.hs` (same scaffold conventions; these tests are pure/DB-only, NOT `@slow`):

```haskell
    describe "isDue" $ do
      it "is due when there is no previous success" $ ...
        -- isDue now section Nothing == True
      it "is due when the last success is older than the schedule" $ ...
        -- schedule daily; lastSuccess = 25 hours before now -> True
      it "is not due when the last success is fresh" $ ...
        -- schedule daily; lastSuccess = 1 hour before now -> False

    describe "decodeBackupTargets" $ do
      it "decodes a valid jsonb payload and drops garbage" $ ...
        -- encode a BackupSection with Aeson, cs to Text, build the tuple;
        -- plus one tuple with "not json" -> only the valid one survives

    describe "scheduler pass" $ inM $ beforeM_ truncateDBM $ do
      it "runs due targets and records a failed row when the guest is unreachable" $ do
        -- addTestServer with readyAt set and ipv4 "127.0.0.1:1" (nothing listens),
        -- a build row via testBuild giving repo/package (see how ArtifactsSpec
        -- creates builds), setServerBackups with a daily section,
        -- plug an in-memory BackupStore (copy the withFakeStore pattern from
        -- ArtifactsSpec.hs, adapted: record puts in an IORef Map),
        -- run schedulerPass (export it from Scheduler for the test),
        -- then: exactly one backups row exists with status == "failed"
        -- and error mentioning ssh/exit; no object uploaded.
```

Write the `...` out fully. For plugging the store: `local (#backupStore ?~ store) $ …`.

- [ ] **Step 3: Run to verify failure, then implement**

`backend/src/Garnix/Backups.hs` — full contents:

```haskell
-- | Server-backup capture pipeline: SSH-pull a tar of the configured paths
-- from a live guest, compress, content-address, upload. The backend is the
-- only credential holder — guests never see bucket keys (design:
-- docs/plans/2026-07-20-server-backups-design.md).
module Garnix.Backups
  ( BackupTarget (..),
    runServerBackup,
    backupObjectKey,
    decodeBackupTargets,
    isDue,
  )
where

import Data.Aeson qualified as Aeson
import Data.Time (UTCTime, diffUTCTime)
import Garnix.DB.Backups qualified as DB
import Garnix.Hosting.ServerPool qualified as ServerPool
import Garnix.Monad
import Garnix.Prelude
import Garnix.S3Cache (getFileHash)
import Garnix.Types
import Garnix.YamlConfig (BackupSection (..), BackupSchedule (..))
import System.Directory (getFileSize, removeFile)
import System.IO (IOMode (WriteMode), withFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Proc

data BackupTarget = BackupTarget
  { _backupTargetServerId :: ServerId,
    _backupTargetIpv4 :: Text,
    _backupTargetRepoUser :: GhRepoOwner,
    _backupTargetRepoName :: GhRepoName,
    _backupTargetBranch :: Maybe Branch,
    _backupTargetConfiguration :: Text,
    _backupTargetPersistenceName :: Maybe Text,
    _backupTargetSection :: BackupSection
  }

backupObjectKey :: Text -> Text
backupObjectKey hash = "backups/" <> hash <> ".tar.zst"

-- | A target is due when it has never succeeded, or the last success is at
-- least the schedule interval old.
isDue :: UTCTime -> BackupSection -> Maybe UTCTime -> Bool
isDue _ _ Nothing = True
isDue now section (Just lastSuccess) =
  diffUTCTime now lastSuccess
    >= fromIntegral (_backupScheduleHours (_backupSectionSchedule section) * 3600)

decodeBackupTargets ::
  [(ServerId, Text, GhRepoOwner, GhRepoName, Maybe Branch, Text, Maybe Text, Text, Maybe UTCTime)] ->
  [(BackupTarget, Maybe UTCTime)]
decodeBackupTargets = mapMaybe decodeOne
  where
    decodeOne (serverId, ipv4, owner, repo, branch, config, persistence, jsonText, lastSuccess) =
      case Aeson.decode (cs jsonText) of
        Nothing -> Nothing
        Just section ->
          Just (BackupTarget serverId ipv4 owner repo branch config persistence section, lastSuccess)

-- | One full backup run. Inserts a running row first; ANY failure finalizes
-- it as failed (with the error) and never propagates — the scheduler loop
-- must survive every kind of broken guest.
runServerBackup :: BackupStore -> BackupTarget -> Text -> M ()
runServerBackup store target kind = do
  alreadyRunning <- DB.hasRunningBackup (_backupTargetServerId target)
  if alreadyRunning
    then log Informational $ "backup: skipping " <> show (_backupTargetServerId target) <> ", one is already running"
    else do
      backupId <-
        DB.insertRunningBackup
          (_backupTargetServerId target)
          (_backupTargetRepoUser target)
          (_backupTargetRepoName target)
          (_backupTargetBranch target)
          (_backupTargetConfiguration target)
          (_backupTargetPersistenceName target)
          kind
      capture backupId `catchEither` \e -> do
        let msg = either show show e
        log Informational $ "backup " <> show backupId <> " failed: " <> cs msg
        DB.finalizeBackupFailure backupId (cs msg)
  where
    section = _backupTargetSection target

    capture backupId = withSystemTempDirectory "garnix-backup" $ \tmpDir -> do
      let spool = tmpDir <> "/backup.tar"
      (ip, sshArgs) <- ServerPool.sshArgsForAddress (_backupTargetIpv4 target)
      -- 1. pre-hook (10 min cap via guest coreutils timeout)
      forM_ (_backupSectionPreBackupCommand section) $ \hook ->
        runHook sshArgs ip "preBackupCommand" hook
      -- 2. tar stream -> spool (binary; cradle captures Text, so use
      --    System.Process with a file handle; 30 min cap via local timeout)
      tarResult <- liftIO $ withFile spool WriteMode $ \h -> do
        (_, _, mErr, ph) <-
          Proc.createProcess
            ( Proc.proc
                "timeout"
                ( ["1800", "ssh"]
                    <> map cs sshArgs
                    <> [ cs ("garnix@" <> ip),
                         "sudo", "-n", "tar", "--sort=name", "--numeric-owner", "-cf", "-"
                       ]
                    <> map cs (_backupSectionPaths section)
                )
            )
              { Proc.std_out = Proc.UseHandle h,
                Proc.std_err = Proc.CreatePipe
              }
        errOut <- maybe (pure "") System.IO.hGetContents mErr
        code <- Proc.waitForProcess ph
        pure (code, errOut)
      -- 3. post-hook ALWAYS runs (cleanup semantics), before failure handling
      postHookResult <-
        tryEither
          $ forM_ (_backupSectionPostBackupCommand section)
          $ \hook -> runHook sshArgs ip "postBackupCommand" hook
      case fst tarResult of
        ExitFailure code ->
          throw $ OtherError $ "backup tar failed (exit " <> show code <> "): " <> snd tarResult
        ExitSuccess -> pure ()
      case postHookResult of
        Left e -> throw $ OtherError $ "postBackupCommand failed: " <> show e
        Right () -> pure ()
      -- 4. compress (zstd is in the service PATH via the NixOS module)
      runSubProcess $ cmd "zstd" & addArgs ["-q", "--rm", cs spool]
      let compressed = spool <> ".zst"
      -- 5. size cap
      size <- liftIO $ getFileSize compressed
      when (fromIntegral size > _backupStoreMaxSize store)
        $ throw
        $ OtherError
        $ "backup exceeds the size cap: " <> show size <> " > " <> show (_backupStoreMaxSize store)
      -- 6. content-address + upload (skip upload when the object exists)
      hash <- getFileHash compressed
      exists <- DB.backupObjectExists hash
      unless exists $ _backupStorePutFile store (backupObjectKey hash) compressed
      DB.upsertBackupObject hash (fromIntegral size)
      DB.finalizeBackupSuccess backupId hash (fromIntegral size)
      log Informational
        $ "backup " <> show backupId <> " done: " <> cs (backupObjectKey hash) <> " (" <> show size <> " bytes)"

    -- Hooks run as root via sudo sh -c, capped at 10 minutes with the guest's
    -- coreutils timeout. Passing the hook as ONE argv element after sh -c
    -- avoids local shell quoting entirely.
    runHook sshArgs ip label hook = do
      result <-
        tryEither
          $ runSubProcess
          $ cmd "ssh"
          & addArgs
            ( sshArgs
                <> [ "garnix@" <> ip,
                     "sudo", "-n", "timeout", "600", "sh", "-c", hook
                   ]
            )
      case result of
        Left e -> throw $ OtherError $ label <> " failed: " <> show e
        Right () -> pure ()
```

Adjustments the implementer must make by reading neighbors (each is a one-liner, verify by grep in the named file):
- `catchEither` / `tryEither`: `Deploy.hs` uses `catchEither` (grep it there for the import source, likely `Garnix.Monad` or a prelude). If `tryEither` doesn't exist, express the always-run-post-hook with the same `catchEither` shape: `(Right <$> action) \`catchEither\` (pure . Left)`.
- `runSubProcess`/`cmd`/`addArgs` imports: copy from `Deploy.hs`'s import of the cradle helpers.
- `ExitFailure`/`ExitSuccess`: `System.Exit`. `hGetContents`: `System.IO`. If `System.IO.Temp` isn't a dependency (`grep temporary backend/garnix.cabal`), create the spool under `view #buildLogsDir`-style state dir instead: `emptyDir <- view #emptyDir` is NOT writable — instead use `liftIO $ createTempDirectory "/tmp" "garnix-backup"` from whatever temp helper the codebase already uses (`grep -rn "TempDirectory\|withSystemTempDirectory\|mktemp" backend/src | head` and copy the established idiom; `Garnix.Build` modules create scratch dirs).
- `log Informational` is the codebase's logger (as in `Reaper.hs`).

`backend/src/Garnix/Backups/Scheduler.hs` — full contents:

```haskell
-- | The backup scheduler: every 5 minutes, find live servers whose backups
-- are due and run them sequentially (one guest at a time — backups are IO- and
-- network-heavy; a household-scale instance never needs parallel capture).
module Garnix.Backups.Scheduler
  ( initializeBackupScheduler,
    schedulerPass,
  )
where

import Data.Time (getCurrentTime)
import Garnix.Backups
import Garnix.DB.Backups qualified as DB
import Garnix.Duration
import Garnix.Monad
import Garnix.Monad.NoThrow qualified as NoThrow
import Garnix.Prelude

initializeBackupScheduler :: M ThreadId
initializeBackupScheduler = withTextSpan ("tag", "backup scheduler thread") $ do
  NoThrow.forkForever (fromMinutes @Int 5) schedulerPass

schedulerPass :: M ()
schedulerPass =
  view #backupStore >>= \case
    Nothing -> pure ()
    Just store -> do
      now <- liftIO getCurrentTime
      targets <- decodeBackupTargets <$> DB.getLiveBackupTargets
      let due = [t | (t, lastSuccess) <- targets, isDue now (_backupTargetSection t) lastSuccess]
      forM_ due $ \target -> runServerBackup store target "scheduled"
```

Wire the launch in `backend/src/Garnix.hs`, directly after the artifact-reaper launch (anchor: `grep -n "initializeArtifactReaper" backend/src/Garnix.hs`):

```haskell
      when (isJust (env ^. #backupStore)) $ do
        void $ runM env BackupScheduler.initializeBackupScheduler
        void $ runM env BackupReaper.initializeBackupReaper
```

with imports `import Garnix.Backups.Scheduler qualified as BackupScheduler` and `import Garnix.Backups.Reaper qualified as BackupReaper` next to the ArtifactReaper import. (BackupReaper is Task 9 — to keep this task compiling, add ONLY the scheduler line now and the reaper line in Task 9.)

`withTextSpan`: copy the exact usage from `Artifacts/Reaper.hs` — if the signature differs, mirror it.

- [ ] **Step 4: Register modules in cabal, run the tests**

`Garnix.Backups` + `Garnix.Backups.Scheduler` (both lists), `Garnix.Backups.SchedulerSpec` (test list). Then dev-shell:

```
cabal run spec -- --match "isDue" --match "decodeBackupTargets" --match "scheduler pass"
```

Expected: PASS (the unreachable-guest case takes ~15s — ssh ConnectTimeout).

- [ ] **Step 5: Commit**

```bash
git add backend/src/Garnix/Backups.hs backend/src/Garnix/Backups/Scheduler.hs \
        backend/test/spec/Garnix/Backups/SchedulerSpec.hs backend/src/Garnix/S3Cache.hs \
        backend/src/Garnix.hs backend/garnix.cabal
git commit -m "feat(backups): capture pipeline (hooks, tar-over-ssh, zstd, size cap, dedupe) + 5-min scheduler"
```

---

### Task 9: `Garnix.Backups.Reaper` + restore pipeline

**Files:**
- Create: `backend/src/Garnix/Backups/Reaper.hs`
- Modify: `backend/src/Garnix/Backups.hs` (add `runServerRestore`)
- Modify: `backend/src/Garnix.hs` (add the reaper launch line from Task 8's block)
- Modify: `backend/garnix.cabal` (register `Garnix.Backups.Reaper` both lists)

**Interfaces:**
- Consumes: Task 6 queries; `BackupRow` fields.
- Produces: `initializeBackupReaper :: M ThreadId`; `runServerRestore :: BackupStore -> BackupRow -> ServerInfo -> Text -> M ()` (store, snapshot, target live server, initiatedBy username) exported from `Garnix.Backups`.

- [ ] **Step 1: Write the reaper**

`backend/src/Garnix/Backups/Reaper.hs` — full contents (clone of `Artifacts/Reaper.hs`):

```haskell
-- | Retention reaper for server backups: hourly; deletes expired successful
-- rows (per-repo overrides, locks, keep-latest — which DEFAULTS ON for
-- backups), prunes stale failed rows, sweeps running rows orphaned by a
-- backend restart, then GCs unreferenced storage objects (bucket object
-- first, bookkeeping row second, so a crash in between retries next pass).
module Garnix.Backups.Reaper
  ( initializeBackupReaper,
    reapOnce,
  )
where

import Garnix.Backups (backupObjectKey)
import Garnix.DB.Backups qualified as DB
import Garnix.Duration
import Garnix.Monad
import Garnix.Monad.NoThrow qualified as NoThrow
import Garnix.Prelude

initializeBackupReaper :: M ThreadId
initializeBackupReaper = withTextSpan ("tag", "backup reaper thread") $ do
  NoThrow.forkForever (fromHours @Int 1) reapOnce

reapOnce :: M ()
reapOnce = do
  stale <- DB.failStaleRunningBackups
  when (stale > 0)
    $ log Informational
    $ "backup reaper: failed " <> show stale <> " stale running backups"
  reaped <- DB.reapExpiredBackupRows
  when (reaped > 0)
    $ log Informational
    $ "backup reaper: deleted " <> show reaped <> " expired backup rows"
  pruned <- DB.pruneFailedBackupRows
  when (pruned > 0)
    $ log Informational
    $ "backup reaper: pruned " <> show pruned <> " failed backup rows"
  view #backupStore >>= \case
    Nothing -> pure ()
    Just store -> do
      orphans <- DB.getOrphanedBackupObjects
      forM_ orphans $ \hash -> do
        _backupStoreDeleteObject store (backupObjectKey hash)
        DB.deleteBackupObject hash
```

- [ ] **Step 2: Add the restore pipeline to `Garnix.Backups`**

Append to `backend/src/Garnix/Backups.hs` (and export `runServerRestore`):

```haskell
-- | Restore a snapshot onto a live server: download, verify hash, pre-hook,
-- decompress backend-side (no zstd needed on the guest), stream plain tar
-- into the guest over SSH stdin, post-hook (always attempted). Audit-logged
-- to backup_restores; failures finalize the row and rethrow so the API
-- caller's fork logs it.
runServerRestore :: BackupStore -> DB.BackupRow -> ServerInfo -> Text -> M ()
runServerRestore store row server initiatedBy = do
  objectHash <- case DB._backupRowObjectHash row of
    Nothing -> throw $ OtherError "backup has no stored object (not a successful snapshot)"
    Just h -> pure h
  restoreId <- DB.insertRunningRestore (DB._backupRowId row) (server ^. id) initiatedBy
  restore objectHash `catchEither` \e -> do
    let msg = either show show e
    DB.finalizeRestoreFailure restoreId (cs msg)
    throw $ OtherError $ "restore failed: " <> cs msg
  DB.finalizeRestoreSuccess restoreId
  where
    section = ... -- decode current section: DB.getServerBackups (server ^. id);
                  -- hooks come from the TARGET server's CURRENT config (spec §6),
                  -- Nothing -> no hooks.
    restore objectHash = withSystemTempDirectory "garnix-restore" $ \tmpDir -> do
      let compressed = tmpDir <> "/restore.tar.zst"
      _backupStoreGetFile store (backupObjectKey objectHash) compressed
      actualHash <- getFileHash compressed
      unless (actualHash == objectHash)
        $ throw $ OtherError $ "downloaded object hash mismatch: " <> cs actualHash
      runSubProcess $ cmd "zstd" & addArgs ["-dq", "--rm", cs compressed]
      let plainTar = tmpDir <> "/restore.tar"
      (ip, sshArgs) <- ServerPool.sshArgsForAddress (server ^. ipv4Addr)
      mSection <- DB.getServerBackups (server ^. id)
      forM_ (mSection >>= _backupSectionPreRestoreCommand) $ \hook ->
        runHook sshArgs ip "preRestoreCommand" hook
      untarResult <- liftIO $ withFile plainTar ReadMode $ \h -> do
        (_, _, mErr, ph) <-
          Proc.createProcess
            ( Proc.proc "timeout"
                ( ["1800", "ssh"] <> map cs sshArgs
                    <> [cs ("garnix@" <> ip), "sudo", "-n", "tar", "-xf", "-", "-C", "/"]
                )
            ) { Proc.std_in = Proc.UseHandle h, Proc.std_err = Proc.CreatePipe }
        errOut <- maybe (pure "") System.IO.hGetContents mErr
        code <- Proc.waitForProcess ph
        pure (code, errOut)
      postHookResult <-
        tryEither
          $ forM_ (mSection >>= _backupSectionPostRestoreCommand)
          $ \hook -> runHook sshArgs ip "postRestoreCommand" hook
      case fst untarResult of
        ExitFailure code ->
          throw $ OtherError $ "restore untar failed (exit " <> show code <> "): " <> snd untarResult
        ExitSuccess -> pure ()
      case postHookResult of
        Left e -> throw $ OtherError $ "postRestoreCommand failed: " <> show e
        Right () -> pure ()
```

Replace the `section = ...` placeholder by inlining `DB.getServerBackups` where shown (`mSection`) — delete the unused `where` binding. `ReadMode` from `System.IO`. Reuse `runHook` (it's in scope in the same module — lift it from `runServerBackup`'s `where` clause to a top-level private function so both pipelines share it, taking `(sshArgs, ip, label, hook)`).

- [ ] **Step 3: Wire the reaper launch, register, compile**

Add the `BackupReaper.initializeBackupReaper` line (Task 8 showed the block) + import. Register `Garnix.Backups.Reaper` in cabal (both lists). Dev-shell `cabal build lib:garnix` → compiles. Reaper retention behavior is already covered by Task 6's DB tests; the full restore round-trip is exercised in Task 15's `@slow` test.

- [ ] **Step 4: Commit**

```bash
git add backend/src/Garnix/Backups/Reaper.hs backend/src/Garnix/Backups.hs backend/src/Garnix.hs backend/garnix.cabal
git commit -m "feat(backups): hourly retention reaper + object GC; restore pipeline with hooks"
```

---

### Task 10: `Garnix.API.Backups` + mount

**Files:**
- Create: `backend/src/Garnix/API/Backups.hs`
- Modify: `backend/src/Garnix/API.hs`
- Create: `backend/test/spec/Garnix/API/BackupsSpec.hs`
- Modify: `backend/garnix.cabal` (register `Garnix.API.Backups` both lists — between `Garnix.API.Auth` and `Garnix.API.Badges`; `Garnix.API.BackupsSpec` in test list)

**Interfaces:**
- Consumes: everything above.
- Produces: routes under `/api/backups/...`:
  - `GET repo/<owner>/<repo>` → `[BackupDto]`
  - `GET server/<serverId>` → `[BackupDto]` (current + prior incarnations of that server's repo+configuration)
  - `GET server/<serverId>/restores` → `[RestoreDto]`
  - `GET <backupId>/download` → 302 presigned
  - `GET repo/<owner>/<repo>/<configuration>/latest.tar.zst` → 302 presigned (token-friendly stable URL)
  - `POST server/<serverId>/backup-now` → 200, fires async
  - `POST <backupId>/restore` → 200, fires async
  - `POST|DELETE <backupId>/lock`, `DELETE <backupId>` (admin)
- Auth model: NEVER anonymous. Session user or basic-auth access token (`api` scope) with repo access; everything 404-shaped on missing access. `lock`/`delete` additionally require admin. `backup-now`/`restore` require repo access (owner-level in practice).

- [ ] **Step 1: Write failing API tests**

`backend/test/spec/Garnix/API/BackupsSpec.hs` — copy the scaffold of `backend/test/spec/Garnix/API/ArtifactsSpec.hs` EXACTLY (imports, `anonymous`/`sessionAs`/`basicAuthHeader` fixtures adapted to `backupsAPI`), then cases:

```haskell
    it "404s everything when no backup store is configured" $ ...
      -- _backupsAPIListRepo (anonymous fixture) … `shouldThrowM` NotFound

    it "rejects anonymous access even with a store" $ ...
      -- plug in-memory store via local (#backupStore ?~ …);
      -- list for a repo with rows -> NotFound (never a public branch)

    it "session user with repo access can list; without access gets 404" $ ...
      -- create user + repo access the way ArtifactsSpec does (copy its
      -- fixture helpers for hasAccessToRepo-backed users)

    it "download 302s to a presigned URL for an accessible snapshot" $ ...
      -- in-memory store's presignGet returns the key; shouldThrowM (RedirectFound "backups/<hash>.tar.zst")

    it "latest.tar.zst resolves the newest successful snapshot" $ ...

    it "lock/delete require admin" $ ...
      -- non-admin session with repo access -> Unauthorized (copy the
      -- requireAdmin failure expectation from ArtifactsSpec's lock tests)

    it "backup-now 409s when a backup is already running" $ ...
      -- insertRunningBackup for the server first; then _backupsAPIBackupNow -> shouldThrowM (matching OtherError/Conflict per implementation)
```

Write all bodies fully; reuse `addTestServer`, `testBuild`, and Task 6 DB helpers for fixtures.

- [ ] **Step 2: Implement the API module**

`backend/src/Garnix/API/Backups.hs`. Model every mechanism on `API/Artifacts.hs` (read it side-by-side). Key content:

```haskell
type Get302 = Get '[JSON] NoContent

data BackupsAPI route = BackupsAPI
  { _backupsAPIListRepo :: route :- "repo" :> Capture "owner" GhRepoOwner :> Capture "repo" GhRepoName :> Get '[JSON] [BackupDto],
    _backupsAPIListServer :: route :- "server" :> Capture "serverId" ServerId :> Get '[JSON] [BackupDto],
    _backupsAPIListRestores :: route :- "server" :> Capture "serverId" ServerId :> "restores" :> Get '[JSON] [RestoreDto],
    _backupsAPIDownload :: route :- Capture "backupId" Int64 :> "download" :> Get302,
    _backupsAPILatest :: route :- "repo" :> Capture "owner" GhRepoOwner :> Capture "repo" GhRepoName :> Capture "configuration" Text :> "latest.tar.zst" :> Get302,
    _backupsAPIBackupNow :: route :- "server" :> Capture "serverId" ServerId :> "backup-now" :> Post '[JSON] NoContent,
    _backupsAPIRestore :: route :- Capture "backupId" Int64 :> "restore" :> Post '[JSON] NoContent,
    _backupsAPILock :: route :- Capture "backupId" Int64 :> "lock" :> Post '[JSON] NoContent,
    _backupsAPIUnlock :: route :- Capture "backupId" Int64 :> "lock" :> Delete '[JSON] NoContent,
    _backupsAPIDelete :: route :- Capture "backupId" Int64 :> Delete '[JSON] NoContent
  }
  deriving (Generic)
```

(For the `Capture … ServerId` type: check how an existing route captures a server id — `grep -n "Capture" backend/src/Garnix/API/Hosts.hs | grep -i server` — and use the identical type; if Hosts captures a raw `Int64`/hashid, do the same and convert.)

DTOs (snake_case via `ourToJSON`; `BackupDto` mirrors `BackupRow` 1:1 plus nothing else; `RestoreDto` mirrors the restore tuple). Handler skeleton:

```haskell
backupsAPI :: AuthResult AuthJwtPayload -> Maybe Text -> BackupsAPI (AsServerT M)
backupsAPI auth authHeader = BackupsAPI { … }
  where
    requireBackupStore =
      view #backupStore >>= \case
        Just store -> pure store
        Nothing -> throw NotFound

    -- NEVER anonymous: no user resolvable, or no repo access -> NotFound
    -- (404-shaped, no existence leak).
    requireRepoAccess owner repo = do
      mUser <- resolveDownloadUser auth authHeader
      user <- maybe (throw NotFound) pure mUser
      allowed <- hasAccessToRepo (Just user) (RepoIsPublic False) owner repo
      unless allowed $ throw NotFound
```

Reuse `resolveDownloadUser`/`accessTokenUser` — they live in `API/Artifacts.hs`; export them from there (add to its export list) and import here, do NOT copy them. Downloads: `authorize row → url <- _backupStorePresignGet store (backupObjectKey hash) → throw (RedirectFound url)`. `backup-now`: `requireRepoAccess` on the server's repo (resolve via `DB.getBackupsForServerConfig`-adjacent lookup — add a small `DB.getServerRepoAndConfig :: ServerId -> M (Maybe (GhRepoOwner, GhRepoName, Text, Text))` (owner, repo, configuration, ipv4) to `Garnix.DB.Backups` if you need it — write it with the same servers→builds join as `getLiveBackupTargets`), 409-equivalent via `throw Conflict` if such an error constructor exists (`grep -n "Conflict" backend/src/Garnix/Types.hs`), else `throw $ OtherError "a backup is already running for this server"`; then `void $ fork $ runServerBackup store target "manual"` (build the `BackupTarget` from the lookup + `DB.getServerBackups`; refuse with `OtherError "server has no backups configured"` when the section is Nothing). `restore`: `requireRepoAccess` on the snapshot's repo, resolve the CURRENT live server for (repo_user, repo_name, configuration) (add `DB.getLiveServerForConfig :: GhRepoOwner -> GhRepoName -> Text -> M (Maybe ServerInfo)` to `Garnix.DB.Backups`, selecting via the same join `WHERE ready_at IS NOT NULL AND ended_at IS NULL AND b.package = ${configuration}` returning through the ServerInfo prism the way `addTestServer` does), 409/`OtherError "no live server to restore onto — deploy it first"` when absent, then `void $ fork $ runServerRestore store row server (userLogin user)` (get the username field the way ArtifactsSpec/API code reads it, e.g. the `GhLogin` — grep `initiated_by`-style usage or use `user ^. #login` per the `User` type). `lock`/`unlock`/`delete`: `requireBackupStore` + `requireAdmin auth` + the DB call (delete refuses locked rows: check `_backupRowLocked` first, `throw $ OtherError "backup is locked"`).

Mount in `backend/src/Garnix/API.hs` — add to the `WholeAPI` record next to the `artifacts` field (copy that line, rename):

```haskell
    backups :: r :- "api" :> "backups" :> Auth '[JWT, Cookie] AuthJwtPayload :> Header "authorization" Text :> ToServantApi BackupsAPI,
```

and in the server value next to the artifacts line:

```haskell
      backups = \auth authHeader -> toServant $ backupsAPI auth authHeader,
```

with `import Garnix.API.Backups (BackupsAPI, backupsAPI)`.

- [ ] **Step 3: Register, run tests**

Cabal registration, then dev-shell `cabal run spec -- --match "Garnix.API.Backups"`. Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add backend/src/Garnix/API/Backups.hs backend/src/Garnix/API.hs backend/src/Garnix/API/Artifacts.hs \
        backend/src/Garnix/DB/Backups.hs backend/test/spec/Garnix/API/BackupsSpec.hs backend/garnix.cabal
git commit -m "feat(backups): /api/backups — list/download/latest/backup-now/restore/lock, never-anonymous"
```

---

### Task 11: Configure-page retention plumbing (backend)

**Files:**
- Modify: `backend/src/Garnix/API/Configure.hs`

**Interfaces:**
- Consumes: Task 6 settings functions.
- Produces: `ConfigureSettingsDto` gains `_configureSettingsDtoBackupRetentionDays :: Int32`, `_configureSettingsDtoBackupKeepLatest :: Bool`, `_configureSettingsDtoBackupRepoOverrides :: [BackupRepoOverrideDto]`, `_configureSettingsDtoBackupUsage :: [BackupUsageDto]`, `_configureSettingsDtoLockedBackups :: [LockedBackupDto]`; routes `PUT configure/backups/default`, `PUT configure/backups/repo/<owner>/<repo>`, `DELETE configure/backups/repo/<owner>/<repo>`.

- [ ] **Step 1: Clone the artifact settings plumbing**

In `backend/src/Garnix/API/Configure.hs`, for EACH artifact settings element (find them all with `grep -n "Artifact" backend/src/Garnix/API/Configure.hs`), add the backup twin directly below it with `Artifact→Backup`/`artifact→backup` renames:

- DTOs: `SetBackupDefaultsDto`, `SetBackupRepoDto`, `BackupRepoOverrideDto`, `BackupUsageDto`, `LockedBackupDto` (fields: id, repo_user, repo_name, configuration, started_at, size — from `getLockedBackups`'s `BackupRow`). Same `ourToJSON`/`ourParseJSON` triples. Add all to the module export list.
- `ConfigureSettingsDto`: the five new fields listed in Interfaces.
- Routes in `ConfigureAPI`: the three `"backups"`-prefixed twins of the `"artifacts"` routes.
- Handlers: twins calling `Backups.setDefaultBackupSettings` / `setRepoBackupSettings` / `deleteRepoBackupSettings` (import `Garnix.DB.Backups qualified as Backups` — note the existing artifact import alias, follow its pattern) — each guarded by `requireSelfHostConfig auth`, with the same `max 0` clamps.
- `_configureAPIGet`: populate the new fields from `getBackupSettings` / `getBackupRepoOverrides` / `getBackupStorageUsage` / `getLockedBackups`, exactly parallel to the artifact lines in the same handler.

- [ ] **Step 2: Compile + spot-test**

Dev-shell `cabal build lib:garnix`, then `cabal run spec -- --match "Configure"`. Expected: existing Configure specs still pass (they don't assert on unknown JSON fields; if one does exact-DTO matching and fails, extend its expected value with the new fields' defaults: 30 / True / [] / [] / []).

- [ ] **Step 3: Commit**

```bash
git add backend/src/Garnix/API/Configure.hs
git commit -m "feat(backups): Configure API — retention defaults, per-repo overrides, usage, locked snapshots"
```

---

### Task 12: NixOS module options

**Files:**
- Modify: `backend/nixos-module.nix`

**Interfaces:**
- Produces: `services.garnixServer.s3Backups` (`null` or `{ bucket : str }`), `services.garnixServer.maxBackupSize` (int bytes, default `4294967296`), env emission of `S3_BACKUPS_BUCKET` + `GARNIX_MAX_BACKUP_SIZE`, and `zstd` on the service PATH.

- [ ] **Step 1: Add the options**

Directly after the `s3Artifacts` option block (anchor: `grep -n "s3Artifacts = lib.mkOption" backend/nixos-module.nix`):

```nix
        s3Backups = lib.mkOption {
          type = lib.types.nullOr (lib.types.submodule {
            options = {
              bucket = lib.mkOption { type = lib.types.str; };
            };
          });
          default = null;
          description = ''
            Server-backup bucket (garnix.yaml `servers[].backups:`). Single private
            bucket; its key pair is read from
            /run/secrets/s3-backups-{access-key-id,secret-access-key}.
            Feature is off when null.
          '';
        };
        maxBackupSize = lib.mkOption {
          type = lib.types.int;
          default = 4294967296;
          description = "Size cap in bytes for one compressed server-backup snapshot (default 4 GiB).";
        };
```

- [ ] **Step 2: Emit the env vars + PATH**

In the systemd `Environment` list, directly after the `s3Artifacts` optionals block (anchor: `grep -n "S3_ARTIFACTS_PUBLIC_BUCKET=" backend/nixos-module.nix`):

```nix
        ++ lib.optionals (config.services.garnixServer.s3Backups != null) [
          "S3_BACKUPS_BUCKET=${config.services.garnixServer.s3Backups.bucket}"
          "GARNIX_MAX_BACKUP_SIZE=${toString config.services.garnixServer.maxBackupSize}"
        ]
```

In the service `path = with pkgs; [ … ]` list (anchor: `grep -n "path = with pkgs" backend/nixos-module.nix`), add `zstd` on its own line after `bzip2`.

- [ ] **Step 3: Gate + commit**

`nix build .#backend_garnixHaskellPackage --no-link` would not evaluate the module — instead check the module parses: `nix flake check` is too broad; a targeted eval is enough if one exists, otherwise rely on Task 14's full build of the flake attrs. Minimal check: `nix-instantiate --parse backend/nixos-module.nix > /dev/null` (syntax only). Expected: no output, exit 0.

```bash
git add backend/nixos-module.nix
git commit -m "feat(backups): s3Backups + maxBackupSize module options, zstd in service PATH"
```

---

### Task 13: Frontend — services + Servers-page Backups modal + Configure section + icon

**Files:**
- Create: `frontend/src/services/backups.ts`
- Modify: `frontend/src/services/configure.ts`
- Modify: `frontend/src/app/servers/page.tsx`
- Modify: `frontend/src/app/configure/page.tsx`
- Create: `frontend/src/components/icons/backup.tsx`

- [ ] **Step 1: `services/backups.ts`** (full file; mirror `services/artifacts.ts` conventions):

```ts
import { z } from "zod";
import { APIResult, fetchFromAPI } from ".";

const backupSchema = z.object({
  id: z.number(),
  server_id: z.number().nullish().transform((v) => v ?? null),
  repo_user: z.string(),
  repo_name: z.string(),
  branch: z.string().nullish().transform((v) => v ?? null),
  configuration: z.string(),
  persistence_name: z.string().nullish().transform((v) => v ?? null),
  object_hash: z.string().nullish().transform((v) => v ?? null),
  status: z.string(), // running | success | failed
  error: z.string().nullish().transform((v) => v ?? null),
  kind: z.string(), // scheduled | manual
  locked: z.boolean(),
  size: z.number().nullish().transform((v) => v ?? null),
  started_at: z.coerce.date(),
  finished_at: z.coerce.date().nullish().transform((v) => v ?? null),
});
export type Backup = z.infer<typeof backupSchema>;

const restoreSchema = z.object({
  id: z.number(),
  backup_id: z.number(),
  status: z.string(),
  error: z.string().nullish().transform((v) => v ?? null),
  initiated_by: z.string(),
  started_at: z.coerce.date(),
  finished_at: z.coerce.date().nullish().transform((v) => v ?? null),
});
export type BackupRestore = z.infer<typeof restoreSchema>;

export const getServerBackups = async (
  serverId: string,
): Promise<APIResult<Array<Backup>>> =>
  await fetchFromAPI(z.array(backupSchema), "GET", `backups/server/${serverId}`);

export const getServerRestores = async (
  serverId: string,
): Promise<APIResult<Array<BackupRestore>>> =>
  await fetchFromAPI(z.array(restoreSchema), "GET", `backups/server/${serverId}/restores`);

export const getRepoBackups = async (
  owner: string,
  repo: string,
): Promise<APIResult<Array<Backup>>> =>
  await fetchFromAPI(z.array(backupSchema), "GET", `backups/repo/${owner}/${repo}`);

export const backupNow = async (serverId: string): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.any(), "POST", `backups/server/${serverId}/backup-now`);

export const restoreBackup = async (backupId: number): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.any(), "POST", `backups/${backupId}/restore`);

export const lockBackup = async (backupId: number): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.any(), "POST", `backups/${backupId}/lock`);

export const unlockBackup = async (backupId: number): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.any(), "DELETE", `backups/${backupId}/lock`);

export const deleteBackup = async (backupId: number): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.any(), "DELETE", `backups/${backupId}`);

// Downloads are 302s to presigned URLs — plain hrefs, not fetches.
export const backupDownloadUrl = (backupId: number): string =>
  `/api/backups/${backupId}/download`;

export const latestBackupUrl = (owner: string, repo: string, configuration: string): string =>
  `/api/backups/repo/${owner}/${repo}/${encodeURIComponent(configuration)}/latest.tar.zst`;
```

(Before finalizing, `grep -n "fetchFromAPI" frontend/src/services/index.ts` and match the actual call signature for POSTs with no body — copy how `redeployServer` in `services/servers.ts` passes/omits `body`.)

- [ ] **Step 2: `services/configure.ts` + settings schema**

Below the three artifact settings functions (anchor: `grep -n "setDefaultArtifactSettings" frontend/src/services/configure.ts`), add their backup twins (`configure/backups/default`, `configure/backups/repo/...`, same body shape). In the `ConfigureSettings` zod schema in the same file, add fields mirroring the artifact ones (`grep -n "artifactRetentionDays\|artifact_retention_days" frontend/src/services/configure.ts` and clone with backup names, camelCase transform included, plus `backupUsage`, `backupRepoOverrides`, `lockedBackups` arrays mirroring their artifact twins' schemas — for `lockedBackups` use fields id/repo_user/repo_name/configuration/started_at/size).

- [ ] **Step 3: `icons/backup.tsx`** (full file):

```tsx
import { SVGProps } from "react";

export const BackupIcon = (props: SVGProps<SVGSVGElement>) => {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      {...props}
    >
      <ellipse cx="12" cy="6" rx="8" ry="3" />
      <path d="M4 6V18C4 19.66 7.58 21 12 21C16.42 21 20 19.66 20 18V6" />
      <path d="M4 12C4 13.66 7.58 15 12 15C16.42 15 20 13.66 20 12" />
    </svg>
  );
};
```

- [ ] **Step 4: Servers page — Backups button + modal**

In `frontend/src/app/servers/page.tsx`:
1. Add modal state next to the existing ones (anchor: `grep -n "redeployModal\|currentLogsModal" frontend/src/app/servers/page.tsx`): `const [backupsModal, setBackupsModal] = React.useState<RunningServer | null>(null);`
2. In the `rowActions` `<td>`, after the `Monitor` button: `{server.status === "Online" ? (<Button onClick={() => setBackupsModal(server)}>Backups</Button>) : null}`
3. Render `{backupsModal ? (<BackupsModal server={backupsModal} close={() => setBackupsModal(null)} />) : null}` next to the other modal renders.
4. Add a `BackupsModal` component in the same file, modeled structurally on `RedeployConfirmationModal` (same Modal/Button primitives — copy its imports and wrapper JSX): it loads `getServerBackups(server.id)` + `getServerRestores(server.id)` on mount (`React.useEffect` + `useState`, or the page's existing data hook if one is used for logs — copy the `ServerLogsModal` data-loading idiom), then renders:
   - a "Back up now" button → `backupNow(server.id)` then reload; disabled while any row has `status === "running"`.
   - a table of snapshots: started_at (locale string), kind, status (error in a `title` tooltip when failed), size (`(size/1024/1024).toFixed(1)` MB when non-null), and per-row actions: `<a href={backupDownloadUrl(b.id)}>Download</a>` (only when `status === "success"`), Lock/Unlock toggle → `lockBackup`/`unlockBackup` then reload, Restore → sets a nested confirm state.
   - the Restore confirmation: requires typing the server's `package_name` into a text input before the confirm button enables (clone the type-to-confirm pattern if `DeleteServerConfirmationModal` has one — check; otherwise a plain input + `disabled={text !== server.package_name}`), calls `restoreBackup(b.id)`, closes, reloads restores list.
   - a small "Restores" list under the table when non-empty (status + initiated_by + started_at).

- [ ] **Step 5: Configure page — BackupSettings**

In `frontend/src/app/configure/page.tsx`: clone the `ArtifactSettings` component (anchor: `grep -n "const ArtifactSettings" frontend/src/app/configure/page.tsx`) into `BackupSettings` in the same file with artifact→backup renames throughout (state from `settings.backupRetentionDays`/`backupKeepLatest`, handlers calling the Step 2 service functions, overrides table, usage list, locked-snapshots list with `unlockBackup`). Mount it directly below `<ArtifactSettings … />` (same `selfHostMode` gate, same props).

- [ ] **Step 6: Typecheck + build**

```bash
cd ~/Development/garnix-ci
git add frontend/src/services/backups.ts frontend/src/components/icons/backup.tsx
nix build .#frontend_default --no-link
```

Expected: exit 0 (runs `next build`, which typechecks). Fix any type errors it reports.

- [ ] **Step 7: Commit**

```bash
git add frontend/src/services/backups.ts frontend/src/services/configure.ts \
        frontend/src/app/servers/page.tsx frontend/src/app/configure/page.tsx \
        frontend/src/components/icons/backup.tsx
git commit -m "feat(backups): Servers-page backups modal (download/restore/lock/backup-now) + Configure retention section"
```

---

### Task 14: Full gates, docs, push

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Authoritative compile gates**

```bash
cd ~/Development/garnix-ci
nix build .#backend_garnixHaskellPackage --no-link --print-out-paths
nix build .#frontend_default --no-link
```

Expected: both exit 0. Check exit codes directly (`echo $status` in fish / `$?` in bash) — do not pipe through anything.

- [ ] **Step 2: Full backend spec run (non-@slow)**

Dev-shell loop with `cabal run spec -- --skip "@slow"`. Expected: 0 failures. (The `@slow` deploy suite runs in CI via the `backend_specs` action after push — ~35-40 min.)

- [ ] **Step 3: README section**

Add a `## Server backups` section to `README.md` after the server-deployments/monitoring sections (find them with `grep -n "^## " README.md`), documenting: the `backups:` garnix.yaml block (copy the example from the spec §1), the S3_BACKUPS_* / `services.garnixServer.s3Backups` operator setup, retention on the Configure page (keep-latest defaults ON), the Servers-page modal, the never-anonymous `/api/backups` + required Caddy SSO bypass (mirror the `/api/artifacts/*` bypass paragraph), and the restore semantics (target = current live server for that configuration; hooks from its current config).

- [ ] **Step 4: Commit + push**

```bash
git add README.md
git commit -m "docs: server backups section"
git push origin main
```

Push triggers the fork's own CI (`backend_specs` ≈ 35-40 min). Check it: the garnix UI's build page for the fork repo. Treat a red `backend_specs` as a real regression (suite has been reliable since 2026-07-19).

---

### Task 15: `@slow` end-to-end spec (real guest round-trip)

**Files:**
- Modify: `backend/test/spec/Garnix/Backups/SchedulerSpec.hs`

This task is separate because it needs the qemu-capable environment (KVM; same requirements as the existing deploy specs). Skip locally if `/dev/kvm` is absent — CI runs it.

- [ ] **Step 1: Write the round-trip test**

Append to `SchedulerSpec.hs`, modeled on how `DeploySpec.hs` uses `TestHelpers.ServerPool.withServerPoolM` to get a REAL provisioned guest (read `DeploySpec.hs`'s simplest `@slow` case first and copy its setup verbatim — pool config, deploy of a trivial config, obtaining `ServerInfo` with a real ipv4):

```haskell
    describe "backup round-trip @slow" $ inM $ beforeM_ truncateDBM $ do
      it "captures, uploads, and restores through a real guest" $ do
        -- 1. real guest via the DeploySpec fixture (copy exactly)
        -- 2. ssh in (TestHelpers ssh helper if one exists, else runSubProcess ssh
        --    with ServerPool.sshArgsFor) and create /var/lib/testdata/hello.txt
        --    with known content, plus a marker file the preBackupCommand touches
        -- 3. in-memory BackupStore that writes putFile to a local Map/dir and
        --    serves getFile back from it
        -- 4. runServerBackup with a section: paths=[/var/lib/testdata],
        --    preBackupCommand="touch /var/lib/testdata/pre-ran"
        -- 5. assert: backups row success; object recorded; pre-ran exists in guest
        -- 6. ssh: rm -rf /var/lib/testdata
        -- 7. runServerRestore with the row; assert hello.txt content restored
```

Write it fully, following the fixtures. Register nothing new (same spec module).

- [ ] **Step 2: Run it (KVM box) or defer to CI**

`cabal run spec -- --match "backup round-trip"` in the dev-shell. Expected: PASS in ~2-4 min. If no KVM locally: push and verify in the CI `backend_specs` run instead.

- [ ] **Step 3: Commit + push**

```bash
git add backend/test/spec/Garnix/Backups/SchedulerSpec.hs
git commit -m "test(backups): @slow real-guest capture/restore round-trip"
git push origin main
```

---

### Task 16: 🛑 OPERATOR CHECKPOINT — Joe creates the bucket, key, and secrets

**This task is performed BY JOE, not by the implementing agent.** Agent: print this checklist verbatim, then STOP and wait for Joe to reply that it's done. Do not proceed to Task 17.

- [ ] **Step 1 (Joe): create the private B2 bucket**

```bash
b2 bucket create garnix-server-backups allPrivate
```

(Or the Backblaze web UI: Buckets → Create — Private. Any bucket name works; remember it.)

- [ ] **Step 2 (Joe): create a single-bucket application key**

```bash
b2 key create --bucket garnix-server-backups garnix-server-backups-rw \
  listBuckets,listFiles,readFiles,writeFiles,deleteFiles
```

Copy the printed `keyID` and `applicationKey` — the applicationKey is shown ONCE.

- [ ] **Step 3 (Joe): store both as agenix secrets in dotfiles-secrets**

From the dotfiles-secrets checkout. **Critical: no trailing newlines** (the AWS Authorization header rejects them — use `printf '%s'`, never `echo`), and never run `agenix -e` with a non-TTY `EDITOR` — use stdin redirection or `secret-helper`:

```bash
cd ~/path/to/dotfiles-secrets   # wherever the checkout lives
printf '%s' '<keyID>'          > /tmp/bk-id
printf '%s' '<applicationKey>' > /tmp/bk-key
agenix -e s3-backups-access-key-id.age     < /tmp/bk-id
agenix -e s3-backups-secret-access-key.age < /tmp/bk-key
rm -f /tmp/bk-id /tmp/bk-key
```

(`secret-helper` equivalents are fine if preferred.)

- [ ] **Step 4 (Joe): record the bucket name as plain data**

In `dotfiles-secrets/garnix.nix`, add the bucket name to the b2 attrset (next to the existing bucket attrs), e.g. attr `serverBackupsBucket`. Commit + push dotfiles-secrets.

- [ ] **Step 5 (Joe): hand back**

Tell the agent "backups bucket + secrets done" (mention the attr name used if different from `serverBackupsBucket`).

---

### Task 17: 🛑 OPERATOR-ASSISTED — dotfiles aspect wiring + deploy

**Runs in `/home/joe/dotfiles` (and requires Joe's session for the deploy). Only start after Task 16's hand-back.**

- [ ] **Step 1: Declare the two secrets in the erdtree garnix aspect**

In `/home/joe/dotfiles/modules/hosts/erdtree/garnix.nix`, find the existing bulk secret declarations for `s3-artifacts-*` (grep `s3-artifacts`) — they map names to `/run/secrets/<name>` with owner `garnix`. Add `s3-backups-access-key-id` and `s3-backups-secret-access-key` to that same list/mapAttrs structure.

- [ ] **Step 2: Set the module option**

Next to `s3Artifacts = …` in the same file (grep `s3Artifacts`), add:

```nix
s3Backups = { bucket = garnixData.b2.serverBackupsBucket; };
```

(using whatever attr name Joe reported in Task 16 Step 5; `garnixData` is already `import "${dotfiles-secrets}/garnix.nix"` in this file.)

- [ ] **Step 3: Caddy SSO bypass for `/api/backups/*`**

Find the `@artifacts` bypass block in the garnixDomain vhost (grep `@artifacts`) and add the twin below it, same shape:

```
@backups path /api/backups/*
handle @backups {
  reverse_proxy 127.0.0.1:8321
}
```

(match the EXACT syntax of the `@artifacts` block including any header stripping it does — copy it verbatim and rename. This is safe because the backend authenticates every `/api/backups` request itself — never anonymous.)

- [ ] **Step 4: Bump the input and deploy**

```bash
cd /home/joe/dotfiles
set -x NIX_CONFIG "access-tokens = github.com=$(gh auth token)"
nix flake update garnix-ci dotfiles-secrets
just build-to-erdtree
```

**Do not deploy while a long fork build (`backend_garnix*`) is running in garnix CI — the restart orphans in-flight builds.** Check the garnix UI first; cancel/wait as needed.

- [ ] **Step 5: Verify on erdtree**

```bash
ssh erdtree 'sudo systemctl show garnixServer -p Environment' | tr ' ' '\n' | grep -E 'S3_BACKUPS|MAX_BACKUP'
ssh erdtree 'sudo ls -la /run/secrets/ | grep s3-backups'
ssh erdtree 'sudo journalctl -u garnixServer --since "-5 min" | grep -i backup' 
```

Expected: `S3_BACKUPS_BUCKET=…` and `GARNIX_MAX_BACKUP_SIZE=4294967296` present; both secret files exist (owner garnix, mode 0440-ish); no backup-related errors in the log (silence is fine — the scheduler only logs when it acts).

- [ ] **Step 6: End-to-end smoke test with a real repo**

Add a `backups:` section to a hosted test repo's `garnix.yaml` (the fork's `examples/hello-server` pattern — any currently-deployed toy server):

```yaml
    backups:
      paths: [ /var/lib ]
      schedule: daily
```

Push → redeploy captures the config → on the Servers page open **Backups** → **Back up now** → within a minute a `success` row with a size appears → **Download** streams a `.tar.zst` → unpack locally and inspect. Then click **Restore** (type-to-confirm) and verify the restores list shows `success`.

- [ ] **Step 7: Update the skill (separate repo, optional follow-up)**

The `using-garnix-ci` agent skill should gain a short "Server backups" subsection (garnix.yaml block, retention on Configure, never-anonymous API + Caddy bypass). That lives in the agent-skills repo — flag it to Joe rather than editing here.

---

## Self-Review (performed while writing)

- **Spec coverage:** yaml surface (T2), capture pipeline + scheduler + manual trigger (T8, T10), single private bucket + key wiring + module option (T4, T5, T12), DB schema with SET NULL + keep-latest-on (T1, T6), retention reaper + object GC (T9), API incl. latest URL + never-anonymous + admin lock/delete (T10), restore with both hooks + audit (T9, T10), Servers-page panel + Configure section + icon (T13), tests incl. @slow round-trip (T6, T8, T10, T15), rollout (T16, T17), README (T14). Spec §2's "bounded concurrency (e.g. 2)" is implemented as sequential (bound = 1) — simpler and within spec intent (log noted in Scheduler haddock).
- **Type consistency:** `backupObjectKey`, `BackupTarget`, `runServerBackup store target kind`, `runServerRestore store row server initiatedBy`, DB signatures — cross-checked against every call site in T8/T9/T10. `object_hash` (nix-base32 sha256) used consistently (DB column, `backupObjectKey`, dedupe, verify-on-restore).
- **Known judgment calls an implementer may hit:** (1) Types↔YamlConfig import cycle — T7 Step 1 gives the decision procedure and the fallback (`Aeson.Value`) with its knock-on change to `setServerBackups`; (2) `withSystemTempDirectory` availability — T8 gives the grep-and-copy instruction; (3) `Conflict` error constructor existence — T10 names the fallback. These are deliberate look-and-copy steps, not open questions.
