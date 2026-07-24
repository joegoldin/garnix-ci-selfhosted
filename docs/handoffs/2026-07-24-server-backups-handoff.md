# Server backups: status and handoff

Date: 2026-07-24 PDT
Branch: `main` (fork `joegoldin/garnix-ci-selfhosted`)
Plan: `docs/plans/2026-07-24-server-backups.md` (17 tasks)
Design: `docs/plans/2026-07-20-server-backups-design.md`

## Purpose

The backups feature is roughly half-landed: **storage, schema, config and UI
exist; nothing actually takes a backup yet.** This document records exactly
what is committed, what is missing, and the traps found the hard way, so the
next agent can resume without re-deriving any of it.

Read the plan for the *how* — every remaining task there still has its full
step-by-step body. This document only records **where we stopped** and
**what the plan does not tell you**.

## Current state: does it build?

**Yes.** Verified at commit `bb05f63` + the tree as of this document:

```
cabal build test:spec   →  CABAL_EXIT=0, 0 errors, [195 of 195] Linking
```

⚠️ **The nix package build does NOT typecheck any of this.**
`nix build .#backend_garnixHaskellPackage` configures with `--disable-tests`
(visible in its `configureFlags`), so it never compiles the spec suite. A green
nix build says nothing about the test code. The real gate is:

```bash
nix develop --command bash -c 'db new && cd backend && cabal build test:spec'
```

`db new` is required: `postgresql-typed`'s `pgSQL` quasi-quoter connects to a
live Postgres *at compile time*, and the devshell's `shellHook` only exports
`PGHOST`/`TPG_*` — it does not start the server. Without it you get
`Network.Socket.connect: does not exist` from `Garnix/DB.hs:35` and it looks
like a code error when it is not.

Do **not** pipe the build through `tail`/`head` — the pipeline returns the
pager's exit status and a failed build reports success. Capture to a file and
echo `$?` (this bit me twice in one session).

## What is DONE (committed)

| Task | What | Commits |
|---|---|---|
| 1 | SQL migration: `backups`, `backup_objects`, `backup_restores`, retention settings, `servers.backups` | `4583ab6` |
| 2 | `garnix.yaml` `servers[].backups` (paths, schedule, backup/restore hooks) + roundtrip tests | `14a6b7d`, `233341b`, `5a415b5` |
| 3 | `BackupStore` record + `Env.backupStore` (feature-gated) | `76c7b7f` |
| 4 | `Garnix.Backups.Store` — S3 impl, streaming get/put, presigned downloads | `f3692e5`, `933943e` |
| 5 | `S3_BACKUPS_*` env wiring + `GARNIX_MAX_BACKUP_SIZE` (default 4 GiB) | `d7a7567` |
| 6 | `Garnix.DB.Backups` — full query layer (31 functions), retention CTE, truncate helpers | `d3ada05`, `e1b95a7` |
| 7 | Thread `backups:` through deploy → `servers.backups` jsonb | `bb05f63` |
| 12 | NixOS module options `s3Backups`, `maxBackupSize`, zstd on PATH | `10beff1` |
| 13 | Frontend: Servers-page backups modal, `services/backups.ts`, icon, Configure retention section | `77a28fa`, `7694b01` |

`Garnix.DB.Backups` is the most complete piece — it already exports everything
the remaining tasks need (`insertRunningBackup`, `finalizeBackupSuccess/Failure`,
`getLiveBackupTargets`, `reapExpiredBackupRows`, `insertRunningRestore`,
`getBackupSettings`, …). 11 examples in `Garnix/DB/BackupsSpec.hs`.

## What is NOT done

These modules **do not exist yet**:

```
backend/src/Garnix/Backups.hs             ← capture pipeline   (Task 8)
backend/src/Garnix/Backups/Scheduler.hs   ← the thing that fires (Task 8)
backend/src/Garnix/Backups/Reaper.hs      ← retention/orphans  (Task 9)
backend/src/Garnix/API/Backups.hs         ← HTTP surface       (Task 10)
```

| Task | What remains |
|---|---|
| 8 | `Garnix.Backups` capture pipeline + `Scheduler`; export `getFileHash` from `S3Cache`; launch scheduler in `Garnix.hs` |
| 9 | `Backups.Reaper` + `runServerRestore`; reaper launch line; register module in `garnix.cabal` |
| 10 | `Garnix.API.Backups` + mount in `API.hs`; register in `garnix.cabal` |
| 11 | Configure-page retention plumbing — `Garnix/API/Configure.hs` has **no** backup code yet (`grep -c backup` → 0) |
| 14 | Full gates, docs, push |
| 15 | `@slow` end-to-end round-trip (needs `/dev/kvm`; CI runs it) |
| 16 | 🛑 OPERATOR: Joe creates the B2 bucket, key, agenix secrets |
| 17 | 🛑 OPERATOR: dotfiles aspect wiring + deploy |

### The sharpest edge: the frontend is ahead of the backend

`frontend/src/services/backups.ts` already calls six endpoints that **do not
exist** (Task 10 was skipped while Task 13 landed):

```
GET  backups/server/{id}            GET  backups/server/{id}/restores
GET  backups/repo/{owner}/{repo}    POST backups/server/{id}/backup-now
POST backups/{backupId}/restore     POST backups/{backupId}/lock
```

So the Backups modal in the Servers page is **live in the UI and will 404**.
Either finish Task 10 promptly or hide the entry point. Do not interpret those
404s as a regression — nothing ever served them.

## Gotchas already paid for

- **`ServerToSpinUp.backupsJson`, not `backups`.** `Garnix.Types` deliberately
  names the field `backupsJson`: `YamlConfig`'s `makeFields ''ServerSection`
  generates a classy lens called `backups`, and `YamlConfig` imports
  `Garnix.Types` unqualified, so a field named `backups` produces
  `Ambiguous occurrence 'backups'` in the export list. Adding `backups` to that
  import's `hiding (...)` list is **not** a fix — `-Werror=dodgy-imports` then
  rejects hiding a name the module does not export. Keep the rename.
- **It is carried as `Maybe Aeson.Value`, not `BackupSection`.** `Garnix.Types`
  cannot import `Garnix.YamlConfig` (YamlConfig already imports Types — cycle).
  Callers decode it back before handing to `DB.Backups.setServerBackups`.
- **Spin-up persists backups explicitly.** `DB.claimServerDB`'s INSERT captures
  `domains` but has no `backups` column, so `startServer` calls
  `setServerBackups` itself, mirroring the redeploy path.
- **Feature-gated off by default:** `Env.backupStore :: Maybe BackupStore`.
  Everything must no-op when it is `Nothing`; the test env leaves it unset.
- **Backup rows outlive servers** by design (retention "keep latest on" CTE) —
  see Task 6 in the plan before touching those queries.
- **`NoImplicitPrelude` is on.** `Prelude.id` does not resolve in this codebase
  (`no module named 'Prelude' is imported`). Use `Garnix.Prelude`'s re-exports
  or a lambda.

## Concurrency warning

Two agents were editing this checkout at the same time on 2026-07-24, which
produced one broken intermediate state (a partial revert of
`Integration/FlakesSpec.hs` that introduced `Prelude.id` and failed to compile,
plus a stale `hiding (backups)` import). Both are resolved as of this commit.

**Before resuming: `git pull`, then run the `cabal build test:spec` gate above
and confirm it is green before writing anything new.** Do not assume the tree
builds because the last commit message says a task is done.

## Suggested order

1. Task 10 (API) — closes the 404s the shipped UI is already producing.
2. Task 8 (capture + scheduler) — the feature does nothing until this exists.
3. Task 9 (reaper + restore), then Task 11 (configure retention).
4. Task 14/15 gates, then hand back for the operator checkpoints (16, 17).
