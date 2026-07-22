# Hosting hardening completion repairs

## Context and success criteria

The erdtree hardening rollout exposed four implementation regressions and one
cleanup defect after the repository test suite had passed:

1. The backend writes a workload-domain URL into a claimed guest's stats
   environment. Reporter failure then aborts first activation.
2. Unclaimed pre-warm guests run a reporter even though no backend server row
   can accept their provisioner ID.
3. Provisioner teardown removes the microVM working directory before all
   path-dependent systemd units have stopped, leaving a tap or failed unit.
4. FOD verification calls `nix build --rebuild` on a fresh guest whose store
   does not contain the baseline output, then labels the resulting Nix
   precondition error as “source unavailable.”
5. The FOD checker opens remote builders as independent Nix stores, bypassing
   the host daemon's canonical store, configured substituters, and
   `buildMachines[*].maxJobs` scheduler.

Completion also requires rolling out the already-pushed operator-skill update
and executing every still-missing runtime and Authentik check in the original
hardening plan.

The work is complete only when a new hello deployment succeeds from a freshly
created pool guest, stats continue to arrive, the replaced guest is cleaned
without residue, and the full plan has direct evidence for every acceptance
criterion.

## Considered approaches

### Stats lifecycle

1. **Backend-owned activation marker and explicit control URL (selected).**
   Keep reporter units in the shared guest module, but do not create
   `/var/lib/garnix/stats.env` in an unclaimed pool guest. Add an explicit
   backend stats-report URL and let the backend create the durable file after
   claim and before repository activation. Exact-2xx failures remain visible
   after claim.
2. Accept `404` for unclaimed IDs. This hides routing and lifecycle failures,
   contradicts the exact-2xx invariant, and cannot distinguish an expected
   pre-claim response from a broken claimed guest.
3. Add a second “claimed” API handshake while retaining provisioner seeding.
   This duplicates backend ownership state inside the guest and adds a protocol
   solely to compensate for creating the marker too early.

Approach 1 has one owner for the claim transition, preserves fail-closed
monitoring, and removes host-specific stats data from pre-warm images.

### Teardown

1. **Explicit ordered unit and link cleanup (selected).** Stop the VM and both
   path-dependent instance units before removing the working directory, delete
   the deterministic `gx<ID>` link idempotently, then remove files/state and
   reset failed state.
2. Rely on `PartOf=microvm@...` propagation. Production evidence shows that
   this did not finish the path-dependent stops before directory deletion.
3. Move the generated tap scripts to a permanent host path. This changes the
   microvm module's ownership model and is larger than necessary for an
   idempotent provisioner cleanup boundary.

Approach 1 makes the daemon's “every trace” contract explicit and testable.

## Component design

### Backend stats endpoint

Add `statsReportUrl :: Text` to `Garnix.Monad.Env`. `Garnix.hs` reads
`GARNIX_STATS_REPORT_URL`, defaulting to `<GARNIX_URL>/api/hosts/stats` for
upstream compatibility. `copyStatsEnv` consumes the full URL directly; it no
longer constructs a control endpoint from `hostingDomain`.

Add `services.garnixServer.statsReportUrl` to `backend/nixos-module.nix` and
export it as `GARNIX_STATS_REPORT_URL` when configured. Dotfiles sets it to the
main Garnix control domain, the same URL previously configured on the local
provisioner.

### Guest reporter ownership

The shared guest profile always contains the reporter service and timer, both
conditioned on `/var/lib/garnix/stats.env`. It no longer defines
`garnix.guest.statsReportUrl` or `garnix.guest.provisionerId`, creates an `/etc`
stats file, or uses tmpfiles to seed the durable marker.

The provisioner no longer receives or emits a stats URL/id. New pool guests
therefore have reporter code but no active reporter. On claim, the backend
writes a regular root-owned stats environment before activation. The activated
repository configuration sees the marker, starts the timer, and reports to the
control API with exact-2xx semantics.

Existing claimed guests retain their regular durable file. The rollout recycles
the one pre-warm guest created by the old seeding model.

### Deterministic teardown

`cleanup_vm(name)` removes exposure first, then performs these best-effort
operations while holding the existing mutation lock:

1. stop `microvm@<name>.service`;
2. stop `microvm-tap-interfaces@<name>.service`;
3. stop `microvm-set-booted@<name>.service`;
4. delete deterministic tap `gx<ID>` if present;
5. remove microVM/spec directories and gcroots;
6. remove dnsmasq state;
7. reset failed state for all three exact instances.

Every operation is idempotent. A missing unit, link, path, gcroot, or dnsmasq
entry is not an error. Unit tests assert that all path-dependent stops precede
the first directory removal and that repeated cleanup remains safe.

### FOD verification on fresh guests

Prepare the FOD output on the selected checker store with an ordinary build,
then run the strict `--rebuild` on that same store. The prepare phase may use a
trusted substitute or build the FOD; either way, the second phase ignores the
baseline output and exposes a lying hash. This matches the sequence already
used by the test implementation and satisfies Nix's requirement that a checked
output be valid before `--rebuild`.

Replace the blanket “every non-hash-mismatch is source unavailable” rule with
fail-closed verification. Builder stderr is attacker-controlled, so no
download/HTTP-looking substring can authenticate a safe exception. A FOD is
green only after a strict rebuild (or a previously recorded strict rebuild)
produces its declared fixed-output path.

The strict phase must execute the original derivation unchanged. Garnix must
not rewrite builder scripts, regenerate the output through a different
derivation, or accept cache presence as proof. Historical, upstream-network,
and manual/EULA-gated failures remain failures and are never inserted into
`verified_fods`.

The 2026-07-22 production journal audit covered all 30 recorded FOD failures in
the inspected window and found five classes: 16 crates.io API rejections across
eight Cargo vendor FODs, four bootstrap placeholder failures, four contradictory
Go vendor-mode failures, two dead Mes `ldexpl.c` URL failures, and four
DisplayLink `requireFile`/EULA failures. This taxonomy is diagnostic only; none
of the classes authorizes changing the derivation under verification. There
were no unclassified failures in the window.

Both phases run through the host's canonical Nix daemon store. The prepare
phase can use paths already hydrated on the host or any configured substituter;
the strict phase rebuilds the original `.drv^*`. The daemon may dispatch that
build to a matching remote builder, where `buildMachines[*].maxJobs` provides
the concurrency cap, then copies the result back into the canonical store.

### Operator skill rollout

`agent-skills` commit `ce670c9` contains all Task 22 content. Update the
correct dotfiles `agent-skills` lock to a revision containing that commit,
rebuild, and verify the installed Nix-store skill rather than editing the source
again.

## Error handling and safety

- Reporter responses remain successful only for HTTP 2xx. Redirects, 4xx/5xx,
  and network failures retry and fail visibly.
- A monitoring failure after claim remains deployment-fatal during activation;
  the endpoint/lifecycle fixes make a healthy claimed guest succeed rather than
  masking failure.
- Teardown remains best-effort so a missing remnant cannot prevent later
  remnants from being cleaned. Tests verify command order and exact targets.
- The rollout checks for active builds before restarting Garnix services.
- The old live hello server is not ended until a replacement is ready.
- No secret values are printed during runtime or Authentik verification.

## Test and rollout design

The implementation follows red-green cycles for:

- full-URL `statsEnvContents` rendering and environment plumbing;
- absence of a pre-claim stats marker in the evaluated guest profile/spec;
- exact reporter response semantics after the lifecycle change;
- ordered, idempotent cleanup of VM units, tap, paths, state, and failed units.
- prepare-then-rebuild behavior for a previously unbuilt FOD, and strict
  separation of genuine fetch failures from verifier failures.
- canonical-daemon FOD execution, including hydrated host paths, configured
  substituters, and normal distributed-builder scheduling.
- isolated real-VM persistence/redeployment scenarios, each with its own pool
  and database lifecycle so asynchronous refill teardown cannot make them
  order-dependent under randomized Hspec execution.

Before push, run targeted tests, the complete backend package/spec gates,
provisioner checks, frontend checks, HLint/import checks, Nix formatting/statix,
and the example NixOS closure.

Rollout order is Garnix push, dotfiles lock/config and skill-input bump, erdtree
rebuild, stale pool recycle, hello lock bump/push, then end-to-end verification.
The final audit repeats Tasks 18-22, including browser-equivalent JWT/terminal
requests, DNAT replacement, remote builder, build-log health, Authentik API
state, and a no-entitlement negative user.
