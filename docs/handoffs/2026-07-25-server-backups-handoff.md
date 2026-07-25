# Server backups: status and handoff (supersedes 2026-07-24)

Date: 2026-07-25 PDT
Branch: `main` (fork `joegoldin/garnix-ci-selfhosted`), pushed at `cb61f30`
Plan: `docs/plans/2026-07-24-server-backups.md` (17 tasks)
Design: `docs/plans/2026-07-20-server-backups-design.md`

## Purpose

The previous handoff (`2026-07-24-server-backups-handoff.md`) recorded a
half-landed feature: storage, schema, config and UI existed, but **nothing took
a backup**. That gap is now closed. **All code tasks (1–15) are done and
verified.** What remains is only the two operator checkpoints, which need Joe.

## Current state: all gates green

Verified on erdtree at `cb61f30`:

```
nix build .#backend_garnixHaskellPackage   → exit 0
nix build .#frontend_default               → exit 0
cabal run spec -- --skip @slow             → 850 examples, 0 failures
cabal run spec -- --match "backup round-trip"  → 1 example, 0 failures (~47s, real KVM guest)
```

The previous handoff's warnings still apply and were paid again this session:

- **The nix package build does NOT typecheck the spec suite** (`--disable-tests`).
  The real gate is `cabal build test:spec` in the dev shell, with `db new` first.
- Do **not** pipe `nix build` through `tail`/`head` — the pipeline returns the
  pager's status and a failed build reports success.
- **A git-repo flake excludes untracked files.** If you develop on a machine
  other than the build host (this session: edit on macOS, build on erdtree via
  rsync), the build host's own git index must also have the new files staged —
  `git add -A` there — or nix fails with `can't find source for Garnix/API/Backups`.
  Staging on your laptop is not enough.

## What landed this session (Tasks 8–11, 14, 15)

| Task | What | Commit |
|---|---|---|
| 8 | `Garnix.Backups` capture pipeline + `Backups.Scheduler` (5-min pass); `getFileHash` exported from `S3Cache` | `fea473d` |
| 9 | `Backups.Reaper` (hourly retention + object GC) + `runServerRestore` | `ca88ce1` |
| 10 | `Garnix.API.Backups` — 10 routes, never-anonymous, mounted at `/api/backups` | `14ad250` |
| 11 | Configure API retention twins (defaults, per-repo overrides, usage, locked snapshots) | `3be4e1e` |
| 15 | `@slow` real-guest capture/restore round-trip | `7bc86f7` |
| 14 | README `## Server backups` section; config-schema golden regenerated | `cb61f30` |

**The frontend's six 404ing endpoints are now served.** The Servers-page Backups
modal and the Configure retention section work end to end.

## Two bugs found and fixed along the way

Both were latent in the handoff state, neither was caused by this session's work:

1. **`server_id` type mismatch.** `frontend/src/services/backups.ts` declared
   `server_id: z.number()`, but `ServerId` is a newtype over `HashId` and
   serializes as a **hashid string** like every other server id in the API. The
   modal would have failed zod parsing the moment the endpoint existed. Fixed to
   `z.string()`, plus a new spec (`API/BackupsSpec.hs`) asserting the exact
   key set so it can't drift again.
2. **Stale config-schema golden.** Task 2 added the `backups:` block to the
   YamlConfig codec but only hand-added 14 lines to
   `.golden/ConfigSchemaSpec/garnix-config-schema.json/golden`; the codec
   generates 36. `ConfigSchemaSpec` had been failing since. Regenerated from
   `actual`.

## Deviations from the plan (deliberate)

- **The `@slow` round-trip lives in `DeploySpec.hs`, not `SchedulerSpec.hs`.**
  The plan said to append it to SchedulerSpec, but `DeploySpec` exports only
  `spec` — its real-guest fixture (`withServerPool` + `withMockRepo` +
  `buildFlake` + `getAllDbServers`) is not importable, so following the plan
  literally meant duplicating ~50 lines of provisioning setup. The test sits
  next to the fixture instead.
- **The round-trip uses `flakeWithPersistence`, not `simpleFlake`.**
  `simpleFlake`'s guest authorizes only `root`; the backup pipeline SSHes as
  `garnix`. Using `simpleFlake` fails with `Permission denied (publickey)` —
  this cost one full VM boot to diagnose.
- **`BadRequest`, not `OtherError`, for client-state conflicts.** The plan
  suggested `throw Conflict` if such a constructor existed, else `OtherError`.
  There is no `Conflict`, and `OtherError` maps to **500**; "a backup is already
  running" and "no live server to restore onto" are client-visible states the
  modal displays, so they use `BadRequest` (400) with a clean message.

## Gotchas (carried forward + new)

Everything in the previous handoff still holds (`backupsJson` naming, the
`Maybe Aeson.Value` carrier, spin-up persisting backups explicitly, the
`Env.backupStore :: Maybe BackupStore` feature gate, backup rows outliving
servers, `NoImplicitPrelude`). New ones:

- **`runSubProcess` vs `runSubProcess_`.** `runSubProcess` is polymorphic in its
  `Cradle.Output`; calling it where the result is discarded gives
  `Ambiguous type variable 'a0' ... (Output a0)`. Use `runSubProcess_` for
  unit-returning commands (e.g. the `zstd` invocations).
- **Read the stderr pipe before `waitForProcess`.** Both the capture and restore
  pipelines `hGetContents` the stderr handle and force it with
  `evaluate (length errOut)` before waiting, or a guest that writes more than a
  pipe buffer of stderr deadlocks.
- **`ourToJSON` omits `Nothing` fields.** A DTO key set assertion must expect
  absent keys for null fields — the frontend parses them as `.nullish()`.
  `BackupDto` for a successful, unnamed snapshot emits neither `error` nor
  `persistence_name`.
- **Hook quoting.** Hooks are passed to the guest as a single shell-quoted argv
  element after `sudo -n timeout 600 sh -c`, so local quoting never applies.
  The same `shellQuote` idiom appears privately in `Hosting/LogStream.hs` and
  `Build/Action.hs`; `Garnix.Backups` has its own copy.
- **Non-admin test users have no repo access.** `hasAccessToRepo` short-circuits
  to `True` for `Admin` and otherwise hits the collaborators lookup, which is
  `RepoNotFound` in tests. That's what makes the never-anonymous 404 assertions
  work: `sessionAs "x" Admin` sees everything, `FreeSubscription` sees nothing.

## What remains: OPERATOR CHECKPOINTS ONLY

Nothing further can land without Joe. Both are unchanged from the plan
(Tasks 16 and 17) — read those task bodies for the verbatim checklists.

- **Task 16:** create the private B2 bucket, create a single-bucket application
  key, store both halves as agenix secrets (`s3-backups-access-key-id`,
  `s3-backups-secret-access-key`) **with no trailing newline** — pipe via stdin,
  never `echo`, never `EDITOR=cp agenix -e` — and record the bucket name in
  `dotfiles-secrets/garnix.nix`.
- **Task 17:** wire the dotfiles aspect (`services.garnixServer.s3Backups`, the
  secret paths, and a Caddy bypass for `/api/backups/*` next to the
  `/api/artifacts/*` one), then `just build-to-erdtree`.

Until `s3Backups` is set, `Env.backupStore` is `Nothing`: the scheduler and
reaper never start, and every `/api/backups` route 404s. That is the designed
off state, not a fault.

## Verifying after deploy

1. Add a `backups:` block to a deployed server's `garnix.yaml` (see the README's
   `## Server backups` section), push, and let it deploy.
2. Servers page → **Backups** → **Back up now**. The row should go
   `running` → `success` with a size.
3. Download the snapshot from the modal (302 to a presigned URL).
4. `sudo journalctl -u garnixServer -f | grep backup` on erdtree shows the
   scheduler's 5-minute passes and each capture's outcome.
