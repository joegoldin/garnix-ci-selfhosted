# Hosting Hardening Completion Repairs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair every failed or missing verification item so the original hosting-hardening plan is implemented, deployed, and supported by requirement-level evidence.

**Architecture:** The backend owns the claim-time stats marker and receives an explicit control-domain URL; pre-warm guests contain inert reporter units but no marker. Provisioner teardown explicitly stops every path-dependent unit and removes the deterministic tap before deleting state. FOD verification prepares its baseline, strictly rebuilds it, fails every unsuccessful check closed, and independently caps direct remote-store sessions. Rollout and verification then cover the complete original plan, including Authentik and operator-skill installation.

**Tech Stack:** Haskell/Servant, Hspec, Python 3 `unittest`, NixOS modules, microvm.nix/systemd, Caddy, PostgreSQL, Authentik REST API, GitHub checks.

## Global Constraints

- Keep exact-2xx reporter semantics; redirects, 4xx/5xx, and network failures remain visible failures.
- Do not expose or print any private key, repo key, Authentik token, or decrypted agenix value.
- Preserve the old live hello server until a replacement is ready.
- Do not stage unrelated/untracked files in Garnix, dotfiles, agent-skills, dotfiles-secrets, or hello.
- Use `apply_patch` for file edits, `nixfmt` plus `statix` for Nix, and fresh verification before each commit/push.
- Execute inline; the user has explicitly authorized work on the current `main` branches.

---

### Task 1: Make the backend own the full stats-report URL

**Files:**
- Modify: `backend/test/spec/Garnix/Hosting/DeploySpec.hs`
- Modify: `backend/src/Garnix/Hosting/Deploy.hs`
- Modify: `backend/src/Garnix/Monad.hs`
- Modify: `backend/src/Garnix.hs`
- Modify: `backend/test/spec/Garnix/TestHelpers/Monad.hs`
- Modify: `backend/nixos-module.nix`

**Interfaces:**
- Consumes: `GARNIX_STATS_REPORT_URL`, with fallback to `GARNIX_URL <> "/api/hosts/stats"`.
- Produces: `Env.statsReportUrl :: Text` and a durable file whose URL line is the exact configured URL.

- [ ] **Step 1: Write the failing full-URL test.** Change the existing test to call:

  ```haskell
  statsEnvContents "https://control.example/internal/stats" (ProvisionedServerId 42)
  ```

  and expect that URL verbatim followed by `GARNIX_PROVISIONER_ID=42`.

- [ ] **Step 2: Run the focused Hspec test and confirm RED.**

  Run the repository's existing Hspec wrapper for
  `Garnix.Hosting.DeploySpec`. Expected: the old function prepends `https://`
  and appends `/api/hosts/stats`, so the assertion fails for the intended
  reason.

- [ ] **Step 3: Implement the environment contract.** Add `statsReportUrl` to
  `Env`, parse `GARNIX_STATS_REPORT_URL` after `GARNIX_URL`, default it from the
  normalized base URL, initialize test environments, and make
  `copyStatsEnv`/`statsEnvContents` use the exact full URL.

- [ ] **Step 4: Add NixOS module wiring.** Add nullable string option
  `services.garnixServer.statsReportUrl` and conditionally export
  `GARNIX_STATS_REPORT_URL`.

- [ ] **Step 5: Run focused Hspec and backend package gates.** Expected: the
  focused test and `nix build .#backend_garnixHaskellPackage --no-link` pass.

### Task 2: Keep the reporter inert until backend claim

**Files:**
- Modify: `provisioner/test_provisionerd_ports.py`
- Modify: `provisioner/provisionerd.py`
- Modify: `provisioner/default.nix`
- Modify: `provisioner/guest-profile.nix`
- Modify: `provisioner/nixos-module.nix`
- Modify: `backend/src/Garnix/API/Hosts.hs`
- Modify: `backend/src/Garnix/Types.hs`
- Modify: `README.md`

**Interfaces:**
- Consumes: `/var/lib/garnix/stats.env` written only by backend claim/deploy.
- Produces: reporter service/timer present in every guest configuration but inactive without that marker.

- [ ] **Step 1: Write a failing generated-spec test.** Add a test asserting
  `write_spec` emits neither `garnix.guest.statsReportUrl` nor
  `garnix.guest.provisionerId`. Expected RED: both lines exist.

- [ ] **Step 2: Change the Nix evaluation assertions to require no seed path.**
  Remove the stats-enabled fixture and assert the profile contains reporter
  units and conditions but never defines `environment.etc."garnix/stats.env"`
  or a stats tmpfiles copy rule.

- [ ] **Step 3: Run Python and Nix checks and confirm RED.** Expected: the new
  Python assertion fails against the generated spec; the Nix check fails until
  the seed configuration is removed.

- [ ] **Step 4: Remove provisioner-side stats injection.** Remove
  `STATS_URL`, the two generated guest assignments, the provisioner
  `statsReportUrl` option/environment field, the two guest options,
  `statsEnabled`, and the conditional `/etc`/tmpfiles block. Keep reporter
  units and exact-2xx script unchanged.

- [ ] **Step 5: Update code comments and README ownership language.** State
  that the backend writes the durable marker after claim, and remove references
  to provisioner injection.

- [ ] **Step 6: Run the Python provisioner check and
  `guestProfileStatsTests`.** Expected: all generated-spec, marker-absence, and
  exact-2xx cases pass.

### Task 3: Make guest teardown deterministic and idempotent

**Files:**
- Modify: `provisioner/test_provisionerd_ports.py`
- Modify: `provisioner/provisionerd.py`
- Modify: `README.md`

**Interfaces:**
- Consumes: VM name `garnix-<id>` and deterministic tap `gx<id>`.
- Produces: `cleanup_vm(name)` that removes exposure, units, link, paths,
  gcroots, dnsmasq state, and failed state without depending on prior presence.

- [ ] **Step 1: Write failing cleanup-order tests.** Patch `run`, `rmtree`,
  `unlink`, `remove_exposure`, and `dnsmasq_drop`; assert all three exact
  systemd instance stops and `ip link delete gx42` occur before the first
  `rmtree`, and `systemctl reset-failed` occurs after cleanup.

- [ ] **Step 2: Add an idempotence test.** Make every mocked target absent and
  call cleanup twice; expect neither call to raise and all exact targets to be
  attempted both times.

- [ ] **Step 3: Run the focused Python tests and confirm RED.** Expected: the
  existing cleanup only stops `microvm@...` and removes directories too early.

- [ ] **Step 4: Implement ordered best-effort cleanup.** Stop
  `microvm@...`, `microvm-tap-interfaces@...`, and
  `microvm-set-booted@...`; delete the exact tap; remove paths/state; reset
  failed state. Keep all commands exact and `check=False`.

- [ ] **Step 5: Run the complete provisioner Python suite.** Expected: all
  allocator, transactional exposure, guest-spec, and cleanup tests pass.

### Task 4: Make FOD checks effective on fresh guests

**Files:**
- Modify: `backend/src/Garnix/Build/FodCheck.hs`
- Modify: `backend/test/spec/Garnix/Build/FodCheckSpec.hs`
- Modify: `README.md`

**Interfaces:**
- Consumes: an FOD derivation and the checker store selected for its system.
- Produces: a prepared baseline followed by a strict rebuild on the same store;
  every preparation or rebuild failure is terminal.

- [ ] **Step 1: Capture the production failure.** Confirm the journal contains
  `some outputs ... are not valid, so checking is not possible` and Nix's
  `--rebuild and --check error if the derivation was not previously built`
  hint, rather than a source-fetch error.
- [ ] **Step 2: Write failing regressions.** Require a previously unbuilt FOD
  to pass the real rebuild implementation, and require the Nix precondition
  error to fail rather than produce a source-unavailable skip.
- [ ] **Step 3: Prepare then rebuild on one store.** Copy the derivation closure
  as before, run an ordinary `nix build` on the selected local/remote store,
  then run `nix build --rebuild` on the same store.
- [ ] **Step 4: Fail closed.** Treat download/fetch/HTTP/mirror/manual-source,
  builder, Nix, SSH, and checker errors as FOD failures. Builder-controlled
  stderr cannot authenticate a source-unavailable exemption.
- [ ] **Step 5: Bound and retry direct remote-store work.** Add
  `services.garnixServer.maxRemoteFodJobs` / `GARNIX_FOD_REMOTE_MAX_JOBS`
  (default `1`), hold a slot across copy/prepare/check, and retry only
  recognized SSH transport failures with bounded jittered backoff. Prove a
  one-job configuration never exceeds one active remote operation.
- [ ] **Step 6: Run focused and complete FOD/backend tests.** Expected: new
  unbuilt-FOD and classification regressions pass, source 403s and lying FODs
  fail, and remote retry/cap regressions pass.

### Task 5: Update docs, format, and run all local gates

**Files:**
- Modify: `README.md`
- Modify: `docs/handoffs/2026-07-21-hosting-hardening-review-handoff.md`
- Modify only if evidence changes: `docs/plans/2026-07-20-garnix-hosting-hardening.md`

**Interfaces:**
- Consumes: final code behavior from Tasks 1-3.
- Produces: accurate operator/developer documentation without premature completion claims.

- [ ] **Step 1: Update docs for explicit URL, claim-owned marker, and teardown.**
- [ ] **Step 2: Run `nixfmt` on changed Nix files and `statix check` on them; address every finding.**
- [ ] **Step 3: Run HLint/import policy, full backend specs/package, frontend tests/lint/knip, provisioner checks, and example guest/NixOS closure builds.**
- [ ] **Step 3a: Keep multi-activation VM scenarios isolated from the shared,
  randomized deploy pool; rerun the complete `Garnix.Deploy` group with any
  captured failure seed after changing their lifecycle.**
- [ ] **Step 4: Run `git diff --check`, inspect the entire diff, stage only intended files, and commit the repair.**

### Task 6: Wire dotfiles and install the updated skill

**Files:**
- Modify: `~/dotfiles/modules/hosts/erdtree/garnix.nix`
- Modify: `~/dotfiles/flake.lock`

**Interfaces:**
- Consumes: new `services.garnixServer.statsReportUrl` and
  `services.garnixServer.maxRemoteFodJobs`; pushed Garnix and agent-skills revisions.
- Produces: erdtree closure with control-domain stats URL, a one-job FOD limit
  for the small external builder, and the installed Task 22 runbook.

- [ ] **Step 1: Replace the local-provisioner stats setting with
  `services.garnixServer.statsReportUrl = "https://${domains.garnixDomain}/api/hosts/stats"`,
  and set `services.garnixServer.maxRemoteFodJobs = 1`.**
- [ ] **Step 2: Push the verified Garnix commit.**
- [ ] **Step 3: Update dotfiles `garnix-ci` and the correct `agent-skills` input; verify both locked revisions.**
- [ ] **Step 4: Run `nixfmt`, `statix`, flake evaluation, and the complete erdtree toplevel build.**
- [ ] **Step 5: Confirm no active builds, commit/push dotfiles, and deploy erdtree.**
- [ ] **Step 6: Verify active services, backend environment URL, Caddy route,
  and installed skill content.**

### Task 7: Recycle safely and prove first deployment

**Files:**
- Modify: `~/Development/garnix-hello/flake.lock`

**Interfaces:**
- Consumes: deployed repaired erdtree and a new unclaimed pool guest.
- Produces: successful hello deployment, continuing stats, and residue-free old candidate cleanup.

- [ ] **Step 1: Remove only the failed candidate/pool rows whose ownership and
  references are proven, then verify automatic destroy leaves no residual
  unit/tap/path/gcroot/DNAT/dnsmasq state.**
- [ ] **Step 2: Recycle the old pre-seeded pool guest and confirm its replacement
  has no `/var/lib/garnix/stats.env` and no failed reporter unit.**
- [ ] **Step 3: Bump hello to the repaired Garnix commit, build its NixOS closure
  locally, commit, and push.**
- [ ] **Step 4: Watch all hello checks to terminal state.** Expected: builds,
  deployment, aggregate, and evaluation checks succeed.
- [ ] **Step 5: Verify the claimed guest has a regular stats file with the
  control-domain URL, reporter 2xx, increasing DB samples, ready state, app
  health, and no failed units; verify the old live version ends only after the
  replacement is ready.**

### Task 8: Complete the original runtime and security audit

**Files:**
- Modify: `docs/handoffs/2026-07-21-hosting-hardening-review-handoff.md`
- Modify: `docs/plans/2026-07-20-garnix-hosting-hardening.md`

**Interfaces:**
- Consumes: deployed final state and original Tasks 18-22 checklist.
- Produces: direct evidence for every plan item and a final accurate handoff.

- [ ] **Step 1: Task 18.** Confirm the remaining private-input exemption is
  intentional; run one exempt positive build and one non-exempt negative build.
- [ ] **Step 2: Task 20 host/guest controls.** Repeat tap isolation including a
  peer test with bridge netfilter temporarily disabled/restored, sysctls,
  ingress firewall, egress, DNAT re-exposure stability, terminal CA positive
  and negative paths, proxy marker, JWT TTL, fluent-bit/build logs, remote
  builder, stats source address, tmpfs and both disk images, and an
  Authentik-gated guest redeploy.
- [ ] **Step 3: Task 21 Authentik.** Use the API token without printing it to
  verify no enrollment route/invitations, exact entitlement bindings and
  memberships, entitlement-derived scope mapping, provider redirect/auth flow,
  and oauth2-proxy group match. Create a uniquely named no-entitlement test
  user, prove HTTP 403, then delete it and verify deletion.
- [ ] **Step 4: Task 22.** Confirm the installed skill contains the marker curl,
  terminal-CA contract, `main` branch, and network-boundary text.
- [ ] **Step 5: Re-read every original task and acceptance item. Mark only
  directly proven checkboxes complete, update the handoff from failure report
  to final evidence, and run documentation whitespace/link checks.**
- [ ] **Step 6: Commit/push final documentation if it belongs in the public
  repository, then verify every repository is clean apart from explicitly
  preserved user-owned files.**
