# Nix-native Server Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-server config declared inside each `nixosConfiguration` (`garnix.server.*`), discovered by the backend post-build; garnix.yaml shrinks to the pre-nix contract.

**Architecture:** Spec: `docs/plans/2026-07-27-nix-native-server-config-design.md` (authoritative — every task implements a numbered spec section). Guest module renders an aggregate `garnix.server.deploySpec` to `/etc/garnix/server.json` (closure-pinning hook store paths); the backend generalizes the persistence `nix eval` to read it, decodes into the existing ServerSection types, unions with legacy yaml servers (duplicate = hard error).

**Tech Stack:** Nix module system (fork guest-profile.nix + garnix-lib), Haskell backend (Build/Package.hs eval, Deploy planning), hspec, jkfridge repo migration.

## Global Constraints

- Repos: fork `/home/joe/Development/garnix-ci` (main), `/home/joe/Development/garnix-lib` (main), fridge `/home/joe/Development/shopping-recipe-fridge-tracker` (main).
- Cabal/dev-shell is single-user (shared dist-newstyle); nix-only tasks may run parallel to it. Never pipe `nix build` through tail/head. hpack invariant (garnix.cabal + package.yaml). Sqitch not needed (no DB change).
- The decoded nix `deploySpec` must produce the SAME Haskell `ServerSection`-equivalent values the yaml codec would — downstream deploy planning unchanged.
- Legacy yaml `servers:` untouched and still tested. Duplicate declaration (same configuration in yaml AND nix) = hard error naming both sources.
- Public repo: no real domain values in fork code/docs/tests.
- Fast specs only (no @slow qemu). Eval-proof pattern: the skipAuthPaths/fwdheaders harness in `.agent-skills/sdd/*-report.md`.
- Commit per task; push with rebase-retry (gh-HTTPS fallback); fridge push LAST (single deploy; autoCancelSuperseded covers races).

---

### Task 1: Guest module options + `/etc/garnix/server.json` + `deploySpec` (spec §1–2)

Fork, nix-only. In `provisioner/guest-profile.nix` (namespace `garnix.server.*`): `deployment` nullable submodule (`type` enum on-branch/on-pull-request, `branch` str, `machine` str default "i1x2", `isPrimary` bool false), `domains` [str] [], `exposeSSH` false, `authorizeDeployerGithubKeys` false, `authorizedSSHKeys` [] , `ports` list-of `{name, port, type enum http/tcp}`, `applicationLog` nullable `{enable, path}`, `backups` nullable (paths non-empty absolute not-/ not-/nix/store — assertions; schedule regex `hourly|daily|weekly|[0-9]+h` default daily; four optional hook strs). Read-only `deploySpec` option aggregating all of it as a JSON-serializable attrset (null deployment ⇒ `deploySpec.deployment = null`). `environment.etc."garnix/server.json".text = builtins.toJSON config.garnix.server.deploySpec;` (unconditional — harmless for non-servers). Assertions mirror yaml codec rules. Eval proofs: options set → server.json contains them AND a hook containing `${pkgs.hello}/bin/hello` puts hello in the system closure (`nixosSystem ... config.system.build.etc` or closure query via `nix-store -q --references` on the built toplevel — show evidence); defaults case → deployment null; assertion cases fire. Docs: module header comment. Commit `feat(guest): garnix.server deployment/backups/domains options + closure-pinned server.json`.

### Task 2: garnix-lib `enable` default true (spec §4)

garnix-lib repo, one option change + description (mirror the isVM flip, commit `0e5dd7a` style). Eval-check: config importing the module with ONLY `persistence = { enable = true; name = "x"; }` evaluates (no explicit enable). Commit + push. Then fork+fridge get it via later flake updates (Task 4 bumps fridge; fork does not pin garnix-lib — verify with `grep garnix-lib ~/Development/garnix-ci/flake.nix`; if the fork's eval machinery pins garnix-lib for module eval (Build/Module.hs pins github:garnix-io/garnix-lib upstream!) check whether the fork's pinned garnix-lib ref needs updating to joegoldin/garnix-lib — grep `garnix-lib` in backend/src; if it pins upstream, DO NOT change it in this task; note it in the report (user repos import joegoldin/garnix-lib directly in their own flakes).

### Task 3: Backend discovery + union (spec §3)

Fork, Haskell (owns cabal slot). Generalize the persistence eval in `backend/src/Garnix/Build/Package.hs` (~line 61-90): one `nix eval --json ...config.garnix.server.deploySpec` per built nixosConfiguration (same guarded-failure semantics — missing option/eval error ⇒ Nothing). Decode JSON into the existing ServerSection-equivalent types (write the FromJSON against the SAME field semantics as YamlConfig's codec; unit-test parity: a golden nix-JSON fixture decodes equal to the yaml-parsed equivalent). Union into deploy planning where yaml `servers:` feeds it today (grep `_garnixConfigServers` consumers); duplicate configuration name across sources ⇒ error `"server '<name>' is declared in both garnix.yaml and its nixosConfiguration — pick one"`. persistence eval can fold INTO deploySpec (persistence is part of the aggregate) — keep the old persistence eval path working for configs without the new module (fallback: try deploySpec first, fall back to bare persistence eval). Fast specs: decoding parity, union, duplicate error, fallback. Gates: targeted dev-shell specs + `nix build .#backend_garnixHaskellPackage --no-link`. Commit `feat(backend): discover servers from nixosConfiguration garnix.server.deploySpec`.

### Task 4: jkfridge migration (spec §5)

Fridge repo. `nix flake update garnix-ci garnix-lib`. flake.nix fridge config: add full `garnix.server` block (real values incl. vanity domain from current garnix.yaml; hooks with `${pkgs.sqlite}/bin/sqlite3` + `${pkgs.coreutils}/bin/{rm,cp}`; keep `systemctl` bare — it's systemd's PATH-guaranteed); persistence stays; drop explicit `enable` (Task 2 default). nix/module.nix: delete `environment.systemPackages = [ pkgs.sqlite ]`. garnix.yaml: drop `servers:` wholesale (4-line file per spec). Gates: toplevel build; `nix eval --json .#nixosConfigurations.fridge.config.garnix.server.deploySpec` shows the full spec with store-path hooks; `nix-store -qR` on toplevel contains the sqlite path. Commit; DO NOT push until Task 5 lands on origin (backend must understand deploySpec before the yaml servers section disappears, or the push undeploys the server — sequencing is the point of this task's gate).

### Task 5: Docs, golden, ship (spec §6)

Fork: README + docs/authentik-cookbook.md get the principle line + example; config-schema golden regenerated if the yaml schema doc text changed. Push fork (rebase-retry). Bump dotfiles garnix-ci input + push. 🛑 OPERATOR: Joe runs `just build-to-erdtree` (backend must be live BEFORE the fridge push). THEN push the fridge commit (Task 4); verify: builds green, `redeployment fridge` succeeds, server row keeps id 71 (in-place), `servers.backups` jsonb in the DB matches the previous values modulo store-path hooks, backup fires on schedule. Ledger everything.

## Self-Review

Spec coverage: §1–2→T1, §3→T3, §4→T2, §5→T4, §6→T5. Sequencing hazard (backend-before-fridge-push) is explicit in T4/T5. Parity requirement carried into T3's golden test. Fork's pinned garnix-lib eval ref flagged in T2 as investigate-don't-change.
