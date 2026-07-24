# Garnix self-hosting, recovery, and FOD correctness: final review handoff

Date: 2026-07-22 PDT

## Purpose

This document is the evidence-based handoff for the work that began with the
hosting-hardening plan and expanded to cover recovery after backend restarts,
strict FOD verification, hosted-server monitoring/logs/terminal behavior,
private-input policy, UI wait-state visibility, documentation, and deployment
examples.

The earlier version of this handoff described a failed first deployment and
several incomplete repairs. Those defects have been fixed. This version records
the final architecture, what is deployed, what was verified, and the small
number of deliberately manual observations that remain. It does not modify the
user-owned original plan in
`docs/plans/2026-07-20-garnix-hosting-hardening.md`.

## Executive outcome

There is no known implementation defect remaining from the approved plans.

- Hosted deployments use the control-plane stats URL, keep the reporter inert
  before claim, and deploy successfully from a fresh pool guest.
- Provisioner teardown stops every path-dependent unit, removes the exact tap,
  clears residual state, and is idempotent.
- Backend restarts resume idempotent orphaned package builds and terminalize
  work that cannot be resumed safely. Deploying erdtree no longer leaves old
  work indefinitely pending.
- FOD checks prepare and strict-rebuild the original derivation unchanged
  through the host's canonical Nix daemon store. They use its local store,
  substituters/Attic cache, and configured remote builders. Every prepare or
  rebuild error fails closed; builder-controlled stderr never creates a
  security bypass.
- The web UI exposes compact, expandable wait chains at the run/build/derivation
  levels and links to the work being awaited.
- The hosting terminal uses repo authorization, declared non-root login users,
  a dedicated short-lived certificate CA, per-session principals, and a source
  address restriction. Direct `joe` login was proven against the deployed
  hello guest.
- Guest network isolation, firewalling, egress restrictions, RAM-only repo
  keys, proxy provenance, Authentik scope checks, and dedicated secret groups
  are present and were exercised with focused runtime checks.
- Hosted-server log streaming is optional, capped at 10,000 lines and 10 MiB,
  and shown beside deployment logs. The reusable guest module, hello example,
  README, hosted docs, and operator skill agree on the contract.
- All rewritten and newly created commits use
  `Joe Goldin <joe@joegold.in>`. No reachable `main` history in any repository
  touched by this work contains `Your Name` or `you@example.com`.

The latest Garnix commit only hardens a test; the user explicitly requested no
new erdtree rebuild for it. The previously deployed runtime remains the version
that supplied the production evidence below.

## Repository state

| Repository | Pushed `main` | Notes |
|---|---:|---|
| `joegoldin/garnix-ci-selfhosted` | `115556eaaebebfa11025fe9feacba2ade3e389f5` | Latest delta is test-only ServerPool teardown hardening. |
| `joegoldin/dotfiles` | `a514e4844b6b1ecdf33e0e3d927e2defaeb58955` | History-rewritten to remove `docs/plans/`; locks Garnix at `115556e` and the redacted skill at `fb64cd0`; not rebuilt to erdtree by request. |
| `joegoldin/garnix-hello` | `95c1b80ccdb1c0cf15c30ba5c2efa79849d7d301` | Locks Garnix at `115556e`; the resulting deployment is green. |
| `joegoldin/agent-skills` | `fb64cd03812f6dae19692a8c3b43a173a8df66b0` | Correct canonical-store FOD and hosting operations guidance; instance-specific builder address redacted from reachable history. |
| `joegoldin/dotfiles-assets` | `78e5d1f80715760b16e5065e29a12d8796b947f8` | Correct hosted docs/sidebar and NixOS 26.05 examples. |

For every row above, local `HEAD == origin/main` at handoff time and the latest
author and committer are exactly `Joe Goldin <joe@joegold.in>`.

Dotfiles source sets that exact name and email in `modules/home/git.nix`, and
the unmanaged placeholder `~/.gitconfig` is absent. The currently activated
Home Manager store generation still says `joegoldin` until the user's next
normal activation; it does not contain `Your Name`, and no rebuild was done
solely to refresh it. All commits made during this repair used the exact
canonical identity explicitly.

Preserved, uncommitted user artifacts in the Garnix worktree:

- `docs/handoffs/` (this handoff)
- `docs/plans/2026-07-20-garnix-hosting-hardening.md`
- two generated `provisioner/__pycache__/*.pyc` files

The unrelated untracked `docs/` directory in `agent-skills` is also preserved.

## Plan-to-implementation audit

### Completion-repair plan

| Task | Result | Evidence |
|---|---|---|
| 1. Full stats-report URL owned by backend | Complete | `GARNIX_STATS_REPORT_URL`, `Env.statsReportUrl`, NixOS option, exact-URL focused tests, and deployed reporter samples use the control domain. |
| 2. Reporter inert until claim | Complete | Pool guests have units but no claim marker; backend writes the durable marker during deployment. The repaired first deployment completed successfully. |
| 3. Deterministic/idempotent teardown | Complete | Python ordering/idempotence tests pass; stale taps/units from the earlier failure were removed and subsequent recycling left no equivalent residue. |
| 4. Effective FOD checks on fresh guests | Complete | Ordinary prepare then unchanged `--rebuild` on the canonical daemon store; no alternate `--store`, no derivation patching, no source-unavailable skip. Focused suite: 32 examples, 0 failures. |
| 5. Docs and local gates | Complete | README and hosted docs match behavior. Frontend, backend focus groups, HLint/import checks, provisioner tests, Nix module checks, and flake evaluation passed. |
| 6. Dotfiles and skill rollout | Complete | Dotfiles pins current Garnix/skill/docs inputs; stats URL, builder limits, exporter ACL, terminal CA, secrets, and runbook are wired. |
| 7. Recycle and prove first deployment | Complete | Fresh hello deployment succeeded at `https://garnix.turnin.quest/run/w29Wk49A`; the final lock bump also deployed successfully at `https://garnix.turnin.quest/run/nk9DPR9D`. Application, NixOS configs, deployment, aggregate, and evaluation checks were green. |
| 8. Runtime/security audit | Complete with two manual UI/API observations documented below | Network, secrets, terminal CA, proxy marker, stats, DNAT, store behavior, and service health were directly checked. Authentik public behavior and code tests fail closed. |

### Original hardening findings

| Finding / requirement | Final state |
|---|---|
| C1 guest-to-guest isolation | Per-tap bridge isolation, pinned bridge netfilter, first-position guest-to-guest drop, guest firewall, and peer tests. |
| H1 terminal repo authorization | Terminal requires access to the deployed repository, not merely organization membership. |
| H2 terminal certificate scope | Declared non-root user, server/session key ID, `+61m`, limited extensions, and `source-address=10.111.0.1/32`. |
| H3 dedicated terminal CA | Separate from deploy identity; durable public half in guests, private half host-only. Raw private-key authentication is denied. |
| H5 guest egress | RFC1918, CGNAT, link-local, and the named remote builder are blocked before NAT; public egress works. |
| M1 repo key at rest | `/var/garnix/keys` is a 4 MiB tmpfs; deployed key is root-only and disk-marker scans did not find the age key. |
| M2 secret group separation | Fluent Bit uses `garnix-opensearch`; backend secrets are not exposed through the broad `garnix` group. |
| M3 proxy provenance | Gateway strips inbound identity/marker headers, injects a secret marker only after authentication, and backend requires the exact marker. |
| M4 private inputs | Trusted owner/org repositories use private cache automatically; external forks are blocked until an admin explicitly approves the observed request. |
| M5 on-demand cache | Allowed-domain decisions are cached with a bounded ~10s TTL (mirrors the resolver's FETCH_INTERVAL); staleness is time-bounded, not event-invalidated. |
| M6 port range | Guest exposure range ends below the host ephemeral range. |
| M7 DNAT collision/staleness | Transactional free-list allocation with compensating rollback and flush-before-add. |
| M8 L2/IPv6 posture | Isolated taps, IPv4-only guests, and RA disabled. |
| Session lifetime | Auth cookie/JWT is 30 minutes; focused auth tests cover marker and exact admin-group behavior. |
| Stats endpoint | Source-gated route (guest bridge subnet AND the reporting guest's own registered IP), exact configured full URL. No cryptographic per-guest token — the guard is source-IP-based. |
| Forge-aware keys | GitHub/Gitea deployer-key lookup follows the actual forge. |
| Remote builder limit | Standard Nix `buildMachines[*].maxJobs`; the small builder is limited to one job. FOD work uses the same scheduler. |

## FOD correctness and security value

The final checker deliberately does **not** special-case individual packages,
rewrite derivations, inject alternate fetch URLs, or trust recognizable error
text. Its sequence is:

1. select each transitive fixed-output derivation not already recorded as
   verified;
2. realize/substitute its baseline output through the normal host daemon;
3. strict-rebuild the same original `.drv^*` through that daemon;
4. record it only when the unchanged rebuild succeeds and Nix validates the
   declared output hash.

This preserves upstream's security property: changing a builder while reusing
an old output hash is detected because the builder is actually executed. It
also gives the checker access to the same local store, Attic/substituters, and
remote-builder scheduler used by ordinary builds.

Production run `https://garnix.turnin.quest/run/3EgQnJ0n` demonstrated the final
path: 152 FODs were skipped because they were already verified, while the one
remaining nixpkgs stage-0 bootstrap source failed closed. That derivation's
builder is intentionally a manual bootstrap placeholder; it is not executable
and was not falsely added to `verified_fods`. Manual/EULA/bootstrap sources and
temporary upstream fetch failures remain visible failures, as required by the
approved design.

Twelve rows whose earlier verification provenance was not trustworthy were
deleted from production. A subsequent query showed no matching rows.

## Recovery and wait-state behavior

- Startup reconciliation groups orphaned work by rerun scope (forge/owner/repo/commit/branch/PR), which is stricter than derivation-path grouping.
- Idempotent package builds are re-queued; non-idempotent run/deployment work
  is terminalized instead of silently replayed.
- Recovery observed in production resumed two build groups and cancelled three
  unsafe orphaned runs. A later superseding push cancelling an older resumed
  build is expected supersession behavior, not restart loss.
- Run pages show `WAITING ON` only when work is genuinely blocked. Each compact
  row expands into the next dependency level and links to the awaited build or
  derivation.
- Header filters and destructive controls are inline and right-aligned using
  the existing Garnix visual language.
- Named configurations can be excluded via `garnix.yaml`; skipped work has a
  real non-blocking terminal status rather than masquerading as success.

## Hosted-server functionality

- Builds and Servers filters sit inline with their page titles.
- Monitoring shows useful CPU and memory cards/charts without redundant sample
  count or last-update cards. It includes erdtree and configured external
  builders.
- The farum-azula metrics exporter accepts Tailscale clients and erdtree's
  secret-derived public IP; a local public connection timed out while erdtree
  successfully fetched metrics.
- Domain verification state is persisted. Every configured domain has a state;
  the Verify control disappears after successful verification.
- The terminal user selector exposes declared login users. `joe` exists on the
  hello guest and direct SSH through exposed port 22000 succeeded.
- The guest terminal-CA fingerprint matched the dedicated host CA:
  `SHA256:tjQejC0q5Mxk1QmDETA1+vE/rIoi3EjBc+NE7c6MXc4`.
- Server logs use a horizontally split modal: deployment logs plus optional
  application log tail. Application logging defaults off; when enabled, its
  path has a safe module default and can be overridden.
- Scrollback is capped at the newest 10,000 lines and 10 MiB in process memory.
- The reusable public guest module carries generic boilerplate. No personal
  secret URL is embedded in a public repository; the public key default is
  generic despite using this instance's stable key material.
- `garnix-hello` imports the reusable module, enables the application log, and
  carries the logrotate ordering regression check.

## Verification matrix

The following fresh, focused gates passed during the final audit. The long full
suite was intentionally not re-run after the last test-only change; the user
asked for the affected suite only.

| Area | Result |
|---|---|
| `Garnix.Hosting.ServerPool` after hardening | 3 consecutive runs, 2 examples each, 0 failures, no closed-handle warning |
| FOD checker | 32 examples, 0 failures |
| Backend recovery/hosting/auth/config focus groups | 209 examples, 0 failures |
| Frontend focused suites | 6 suites / 43 tests plus 2 bracket-route tests, all passing |
| Frontend typecheck, ESLint, knip | passing |
| Provisioner Python | 41 tests, passing |
| HLint and qualified-import policy | passing at `115556e` |
| Guest profile composite/stats/terminal-CA and provisioner port checks | passing |
| Authentik provision Nix check | passing |
| Backend monitoring environment Nix check | passing |
| `nix flake show --json` | passing |
| Latest Garnix CI at handoff creation | No completed failures; only the long backend action/aggregate remained in progress |
| Final hello lock bump | Deployment/build/evaluation/aggregate checks green; strict FOD run `MdBXka0n` failed closed and recorded no false verification |

The final ServerPool test now uses a stalled provisioner for the database-only
reservation assertion. It no longer boots and immediately cancels five QEMU
guests, which was the source of post-success `hGetBuf: handle is closed` noise.

## Runtime evidence

The deployed generation was checked before the final test-only commit:

- `garnixServer`, frontend, Caddy, PostgreSQL, provisioner, Traefik, and related
  services were active with no relevant failed units.
- Caddy terminates the source-gated stats route before Authentik-protected API
  handling.
- Guest taps were isolated; bridge netfilter and firewall ordering matched the
  plan.
- Guest-to-guest traffic failed, gateway and public traffic succeeded, and
  private/internal targets timed out.
- Secret ownership/modes and separate groups matched the declared contract.
- `/var/garnix/keys` was tmpfs; no repository key marker was found on the guest
  root image.
- Stats samples were arriving from the deployed hello guest.
- Successful hello deployment runs are
  `https://garnix.turnin.quest/run/w29Wk49A` and
  `https://garnix.turnin.quest/run/nk9DPR9D`.

The newly pushed Garnix `115556e` changes only a test file. Dotfiles now locks
that revision, but erdtree was not rebuilt because the user explicitly asked
not to rebuild for this commit.

## Authentik evidence and boundary

Safe public checks showed:

- default enrollment and generic enrollment routes return 404;
- unauthenticated invitation API access returns 403;
- the source-enrollment route resolves only to Authentik's access-denied stage;
- the Garnix login redirect preserves the exact callback and requests
  `openid profile email garnix`;
- backend tests require the exact allowed/admin groups and the private proxy
  marker.

The final audit did not decrypt or print an Authentik API token, mutate a
production user, or bypass the gateway to synthesize internal auth headers.
Those operations were intentionally rejected during review. Consequently, a
throwaway no-entitlement browser-user test and a direct authenticated API read
of production group bindings remain manual observations, not known code gaps.
The public flow, proxy behavior, Nix configuration, and focused backend tests
all fail closed.

## Review conclusions

1. The implemented FOD path has not reduced the security value of upstream FOD
   checks. It is stricter than the broken source-unavailable behavior because
   all unverified errors remain failures.
2. Recovery does not replay unsafe side effects. It resumes only work whose
   build operation is idempotent and terminalizes the rest.
3. Guest compromise containment has independent L2, L3/L4, credential, and
   proxy-auth boundaries; no single sysctl or shared key remains the only
   control.
4. The latest un-deployed delta is test-only. No runtime repair is waiting on an
   erdtree rebuild.
5. The only remaining observations are intentionally manual Authentik/browser
   checks and normal in-progress CI caused by the final lock bumps. They do not
   represent unfinished implementation work.
