# Server backups: first-class scheduled backups for hosted servers

**Date:** 2026-07-20
**Status:** Approved design, pending implementation plan
**Pattern:** mirrors the artifacts feature (docs/plans/2026-07-17-artifacts-design.md)
wherever possible; deviations are called out explicitly.

## Problem

Hosted (microVM) servers keep all state on a guest `root.img` that nothing
backs up. The disk is deleted on every VM teardown (persistence-name change,
server removed from garnix.yaml, manual delete, failed-provision retry), and
host-side restic on the operator box covers only garnix's own Postgres + logs.
Stateful apps (the motivating case: a FastAPI + SQLite household app migrating
off Fly.io) currently have to bring their own in-guest backup stack.

This feature makes backups a platform primitive: declared in `garnix.yaml`,
executed by the backend, stored in a dedicated private B2 bucket, governed by
retention config on the Configure page, and surfaced in the UI like artifacts.

## Decisions already made

- **Mechanism: backend pulls over SSH.** The backend scheduler SSHes into the
  guest (existing deploy identity + passwordless sudo), runs hooks, streams a
  tar out, and uploads to B2 itself. No credentials of any kind inside guests.
  (Rejected: guest-push to an API — token management + upload limits; guest
  restic direct to B2 — cloud creds in guests, UI must drive restic.)
- **Restore: full loop in v1.** Download + guarded "Restore to server", with
  **pre/post hooks on both backup and restore** so any app's consistency dance
  is expressible.
- **Storage: one new private B2 bucket with its own single-bucket key pair.**
- **Retention/UI: mirror artifacts** (global default + per-repo override +
  keep-latest + locks, Configure page section, repo/server page surfaces).

## 1. garnix.yaml surface

New optional `backups:` sub-section on a server entry (`ServerSection`,
`backend/src/Garnix/YamlConfig.hs:282-334`), parsed as `BackupSection` the way
`ArtifactSection` (`:549-569`) is:

```yaml
servers:
  - configuration: fridge
    deployment: { type: on-branch, branch: main, machine: i2x2 }
    backups:
      paths: [ /var/lib/jkfridge ]        # required, non-empty, absolute paths
      schedule: daily                      # hourly | daily | weekly | "<N>h"
      preBackupCommand:  "sqlite3 /var/lib/jkfridge/app.db '.backup ...'"
      postBackupCommand: "rm -f ..."
      preRestoreCommand:  "systemctl stop jkfridge"
      postRestoreCommand: "systemctl start jkfridge"
```

- `paths` — required. Validation rejects relative paths, `/nix/store`, and `/`.
- `schedule` — optional, default `daily`. Grammar: the three keywords or an
  `"<N>h"` interval string, minimum `1h`. (No cron expressions in v1.)
- Hooks — optional strings, run in the guest **as root over SSH** via `sh -c`,
  each with a timeout (default 10 min, hard cap). A failing pre-hook aborts
  the operation with a failed row; post-hooks always run (backup post-hook even
  if tar failed — cleanup semantics), their failure marks the row failed but
  does not delete an already-uploaded snapshot.

The `backups:` config travels with the build like `domains` does (captured at
deploy planning, persisted per server — column on `servers`, see §4) so the
scheduler reads current config from the DB, not from re-parsed yaml.

## 2. Capture pipeline

New scheduler `backend/src/Garnix/Backups/Scheduler.hs`, launched in
`backend/src/Garnix.hs` (~line 535) next to `ArtifactReaper`, gated on
`isJust backupStore`, using `NoThrow.forkForever` (a failing pass never kills
the loop). Every 5 minutes: select live servers (`ready_at IS NOT NULL AND
ended_at IS NULL`) with backups configured whose last successful snapshot is
older than their schedule interval; run each due backup (bounded concurrency,
e.g. 2 at a time).

Per backup run:

1. Insert a `backups` row with `status = running`, `started_at = now`.
2. `preBackupCommand` (if set) — SSH root, timeout.
3. `ssh garnix@<ip> "sudo tar --sort=name --numeric-owner -cf - <paths>"`
   streamed to a spool file under the backend's state dir. SSH args from
   `ServerPool.sshArgsFor` (`backend/src/Garnix/Hosting/ServerPool.hs:163-188`),
   same pattern as `captureAndStoreSshUsers`
   (`backend/src/Garnix/Hosting/Deploy.hs:584-611`). Overall transfer timeout;
   spool dir cleaned up on any exit path.
4. `postBackupCommand` (if set).
5. Compress: `zstd` shell-out (new helper alongside the cache's `xz` shell-out,
   `S3Cache.hs:161-166`) → `<sha256>.tar.zst`; sha256 of the compressed object.
6. **Size cap check** — new `maxBackupSize` (module option, default 4 GiB,
   the cache's `maxUploadSize` precedent — artifacts has no cap; backups must,
   they read live disks). Over-cap ⇒ failed row with a clear error.
7. Upload via `putFile` (streams from disk, `Artifacts/Store.hs:51-56`
   pattern); insert/upsert `backup_objects` (dedupe: identical sha256 already
   present ⇒ skip upload); finalize row `status = success`, `size`,
   `finished_at`.

Failures at any step (guest unreachable, hook non-zero, timeout, over-cap,
upload error) finalize the row as `failed` with the error captured — visible
in the UI, never fatal to the scheduler.

Manual trigger: `POST /api/backups/server/<serverId>/backup-now` runs the same
pipeline immediately (409 if one is already running for that server).

## 3. Storage

Single **private-only** bucket — deviation from artifacts' public/private
pair, deliberate: server backups contain runtime state and are always
sensitive, regardless of repo visibility. There is no public routing, no
`bucketFor` logic.

- `backend/src/Garnix/Backups/Store.hs` — `s3BackupStore`: single-env
  simplification of `s3ArtifactStore` (`Artifacts/Store.hs:24-96`): `putFile`,
  `getBytes` (unused in v1 except health checks), `deleteObject`,
  `presignGet` (10-min presigned URLs for downloads — private bucket, no
  stable public URLs).
- Env plumbing (`backend/src/Garnix.hs`, next to `S3_ARTIFACTS_*` at
  `:230-254`): `S3_BACKUPS_BUCKET`, keys via `readOptionalSecret` →
  `/run/secrets/s3-backups-{access-key-id,secret-access-key}`. All-or-nothing:
  bucket set without keys is a hard startup error; nothing set ⇒
  `backupStore = Nothing`, feature off (API 404s, no scheduler).
- `Monad.hs`: `backupStore :: Maybe BackupStore` on Env + `BackupStore`
  record-of-functions (test-pluggable, like `ArtifactStore` `:236-253`).
- `backend/nixos-module.nix`: `services.garnixServer.s3Backups` submodule
  (`bucket`, nullable ⇒ off) + env emission next to the artifacts block
  (`:557-561`) + `maxBackupSize` option.
- Object layout: `backups/<sha256>.tar.zst`. Content-addressed by compressed
  tarball sha256; `--sort=name --numeric-owner` makes unchanged data likely to
  produce identical bytes ⇒ free dedupe, but dedupe is opportunistic, not a
  design guarantee.

## 4. DB schema (`sql/deploy/add-backups.sql`)

```sql
CREATE TABLE backup_objects (
  sha256      text PRIMARY KEY,
  total_size  bigint NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE backups (
  id               bigserial PRIMARY KEY,
  server_id        bigint REFERENCES servers(id) ON DELETE SET NULL,
  repo_user        text NOT NULL,
  repo_name        text NOT NULL,
  branch           text NOT NULL,
  configuration    text NOT NULL,      -- nixosConfigurations.<name>
  persistence_name text,               -- from the build, when set
  sha256           text REFERENCES backup_objects(sha256),
  status           text NOT NULL,      -- running | success | failed
  error            text,
  kind             text NOT NULL DEFAULT 'scheduled',  -- scheduled | manual
  locked           boolean NOT NULL DEFAULT false,
  size             bigint,
  started_at       timestamptz NOT NULL,
  finished_at      timestamptz
);
-- + index (repo_user, repo_name, configuration, started_at DESC)

CREATE TABLE backup_restores (
  id          bigserial PRIMARY KEY,
  backup_id   bigint NOT NULL REFERENCES backups(id),
  server_id   bigint REFERENCES servers(id) ON DELETE SET NULL,
  status      text NOT NULL,           -- running | success | failed
  error       text,
  started_at  timestamptz NOT NULL,
  finished_at timestamptz,
  initiated_by text NOT NULL           -- username, audit
);

ALTER TABLE server_settings ADD COLUMN backup_retention_days int NOT NULL DEFAULT 30;
ALTER TABLE server_settings ADD COLUMN backup_keep_latest boolean NOT NULL DEFAULT true;
ALTER TABLE repo_config ADD COLUMN backup_retention_days int;      -- null = inherit
ALTER TABLE repo_config ADD COLUMN backup_keep_latest boolean;     -- null = inherit
```

Key deviations from the artifacts/server_stats precedents, all deliberate:

- **`server_id` is SET NULL, not CASCADE** (`server_stats` cascades): backup
  rows must outlive the server row — surviving accidental server deletion is
  the core recovery scenario. Repo/branch/configuration identity is
  denormalized onto the row for exactly this reason.
- **`backup_keep_latest` defaults to `true`** (artifacts defaults keep-latest
  off): retention must never delete the last remaining snapshot of a server.
- Retention reaper: same shape as `reapExpiredArtifactRows`
  (`backend/src/Garnix/DB/Artifacts.hs:343-372`) — COALESCE(server default,
  repo override), `row_number()` partition by (repo_user, repo_name,
  configuration) for keep-latest, skip `locked`, then GC `backup_objects` no
  longer referenced (`getOrphanedArtifactObjects` pattern) deleting bucket
  object first, row second. Runs in a `Backups/Reaper.hs` `forkForever 1h`.
- The `servers` table gains a `backups jsonb` column (like `domains`/`exposed`)
  carrying the validated `BackupSection` for the scheduler to read.

## 5. API (`backend/src/Garnix/API/Backups.hs`)

Mounted in `API.hs` like artifacts (`:48`): optional `Auth '[JWT,Cookie]` +
`authorization` header. **Never anonymous** — every route requires a session
user or an access token with `api` scope and repo access
(`accessTokenUser` reuse, `API/Artifacts.hs:347-356`); missing access is
404-shaped (no existence leaks). Whole API 404s when `backupStore` is off.

- `GET /api/backups/repo/<owner>/<repo>` — list (all configurations/branches).
- `GET /api/backups/server/<serverId>` — list for a live server incl. prior
  incarnations (matched by repo + configuration).
- `GET /api/backups/<id>/download` — 302 to a presigned URL.
- `GET /api/backups/repo/<owner>/<repo>/<configuration>/latest.tar.zst` —
  stable latest-successful download (token-friendly, like artifacts' latest).
- `POST /api/backups/server/<serverId>/backup-now` — manual run (owner/admin).
- `POST /api/backups/<id>/restore` — restore (owner/admin, see §6).
- `POST|DELETE /api/backups/<id>/lock`, `DELETE /api/backups/<id>` —
  owner/admin.

Gateway note (operator side, erdtree Caddy): add a `/api/backups/*` SSO bypass
exactly like `/api/artifacts/*` — required so access-token clients (curl)
work. Safe because unlike artifacts there is no anonymous branch: the backend
authenticates every request itself. The existing security invariant stands:
the bypass exposes only this prefix, never the whole backend.

## 6. Restore flow

`POST /api/backups/<id>/restore`, confirmation-gated in the UI (type-the-
server-name style), audit-logged to `backup_restores`.

1. Resolve target: the current live server for the snapshot's
   (repo_user, repo_name, configuration) — explicitly supports restoring a
   previous incarnation's snapshot onto a new VM. No live server ⇒ 409 with a
   "deploy the server first" error. Config mismatch warnings (different
   branch) surfaced in the confirmation dialog.
2. Download snapshot from B2 to spool; verify sha256.
3. `preRestoreCommand` (from the *target server's* current `backups` config).
4. Stream in over SSH: `ssh garnix@<ip> "sudo tar --zstd -xf - -C /"` (paths are
   absolute as captured). Guest tar handles zstd via the guest profile's
   standard environment; fallback: decompress backend-side and pipe plain tar.
5. `postRestoreCommand`.
6. Finalize `backup_restores` row; failures at any step mark it failed with
   the error, post-hook is still attempted after a failed untar (recovery
   semantics), and the UI shows the result on the server page.

## 7. Frontend

- `frontend/src/services/backups.ts` — mirror of `services/artifacts.ts`
  (zod schemas, list/download-href/restore/lock/backup-now).
- **Servers page: Backups panel** per server — snapshot table (time, kind,
  size, duration, status incl. failures with error tooltip, lock toggle),
  Download, Restore (confirmation modal), "Back up now", and a "last backup"
  health chip (green/amber/red by age vs schedule).
- **Configure page: Backups section** cloned from `ArtifactSettings`
  (`frontend/src/app/configure/page.tsx:115-490`): global default retention
  days + keep-latest, per-repo overrides, storage usage, locked snapshots.
- Icon in `frontend/src/components/icons/`.

## 8. Testing

- hspec in the deploy-spec style (they boot real qemu guests): full
  capture→upload→restore round-trip against a test server with an in-memory
  `BackupStore`; hook failure/timeout paths; retention CTE unit tests
  (keep-latest, locks, per-repo override); SET-NULL survival on server delete;
  auth: anonymous rejected, token-with-repo-access accepted, cross-repo 404.
- Compile gates: `nix build .#backend_garnixHaskellPackage` and
  `.#frontend_default`. New spec files join `backend_specs`.

## 9. Rollout (operator side, dotfiles)

1. Create the B2 bucket (private) + one single-bucket key pair.
2. Add `s3-backups-access-key-id.age` / `s3-backups-secret-access-key.age` to
   dotfiles-secrets (stdin, no trailing newline), declare them in the erdtree
   garnix aspect at `/run/secrets/s3-backups-*`.
3. Set `services.garnixServer.s3Backups.bucket` + Caddy `/api/backups/*`
   bypass in the aspect; bump the garnix-ci input; `just build-to-erdtree`.
4. Follow-up (separate change): amend the jkfridge migration spec — its DIY
   in-guest restic section collapses into a `backups:` stanza; decide there
   whether Litestream stays for seconds-level SQLite replication or scheduled
   backups (e.g. `schedule: "1h"` + sqlite pre-hook) are sufficient.
5. Docs: README section + the `using-garnix-ci` skill gains a Backups entry
   (separate agent-skills change).

## Out of scope (v1)

- Incremental/deduplicating formats (restic-style chunking) — revisit if
  storage cost ever matters; retention + opportunistic content-address dedupe
  bound growth for now.
- Cron-expression schedules; per-path include/exclude globs.
- Restore to a *different* configuration or cross-repo restore.
- Backup encryption beyond bucket privacy (B2 at-rest + TLS in transit; the
  operator's bucket, operator's data).
