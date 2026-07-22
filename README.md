# Garnix (self-hosting fork)

> **Disclaimer & attribution:** This is a personal fork of
> [garnix](https://garnix.io) — the Nix-native CI/CD and hosting service built
> by the garnix team — from the upstream repo
> [`garnix-io/garnix-ci`](https://github.com/garnix-io/garnix-ci), which they
> generously open-sourced. All credit for garnix itself goes to its authors
> (see [Acknowledgments](#acknowledgments)). This fork is **not affiliated
> with or endorsed by garnix.io**; it adds a single-tenant *self-host mode* and
> the operational glue to run garnix on your own hardware. If you want managed
> garnix with support, use [garnix.io](https://garnix.io). This fork comes with
> no warranty — you run your own CI, cache, and secrets at your own risk.

Garnix is a CI service for nixified, flake-based GitHub repos: on every push it
evaluates your flake, builds the requested attributes in a sandbox, uploads the
results to its own S3-backed Nix binary cache, and can host `nixosConfigurations`
as servers.

This README documents **how to self-host this fork end-to-end** on a single
NixOS machine. Everything below uses example values — substitute your own:

| Placeholder | Meaning |
|---|---|
| `garnix.example.com` | the web UI / API domain |
| `garnix-cache.example.com` | the binary-cache domain |
| `auth.example.com` | your Authentik (or other OIDC IdP) domain |
| `youruser` | your GitHub username/org |
| `bigbox` | the NixOS host running garnix |

## What this fork adds vs upstream

- **`services.garnixServer.selfHostMode`** — single-tenant mode:
  - billing/Stripe entirely bypassed (every org gets a synthetic unlimited plan);
  - open registration disabled: login is only allowed for requests that came
    through an authenticating reverse proxy which injects
    `X-Auth-Request-Groups` **and** a private `X-Garnix-Proxy-Auth`
    provenance marker matched by the backend; membership of `adminGroup` ⇒
    garnix admin, and missing/mismatched marker configuration fails closed;
  - trusted self-host builds may use **private flake inputs** automatically and
    are permanently routed to the **authenticated** cache bucket. An external
    fork is blocked on its first attempt and appears in the admin approval
    inbox; approved retries keep the same private-cache routing.
- **Restart-safe package builds** — evaluation checkpoints the derivation before
  FOD checking and realization. A `garnixServer` deploy resumes checkpointed
  builds on startup instead of cancelling them; work interrupted before that
  point, and external run processes that cannot be reattached, is closed out
  honestly as Cancelled rather than hanging forever.
- **Hardened FOD verification** — prepare and strict-rebuild happen on the same
  checker store, only recognized source-fetch failures may skip, unknown errors
  fail, transient remote-store errors retry, and direct external-builder work
  has its own `maxRemoteFodJobs` cap.
- **Per-bucket S3 credentials** (`S3_CACHE_PRIVATE_ACCESS_KEY_ID`/`…_SECRET_…`)
  — needed for providers like Backblaze B2 whose keys are all-buckets or
  one-bucket (upstream assumed one key pair for both cache buckets).
- **`GARNIX_CACHE_URL` / `GARNIX_CACHE_PUBLIC_KEY`** parameterized (upstream
  hardcoded `cache.garnix.io`), and the frontend reads the cache domain from
  `/api/config` (netrc examples, etc.).
- **`GARNIX_MODULES_ORG`** — publish [garnix modules](https://garnix.io/docs/modules)
  from your own org's repos instead of `garnix-io`'s.
- **`buildNetRcFile`** — a netrc that is bound into the build sandbox so
  sandboxed evals/builds can substitute from *authenticated* caches (e.g. a
  private [attic](https://github.com/zhaofengli/attic)).
- **External-fork approval inbox** (`/garnix-admin`) — ordinary repositories
  need no setup and never appear there. If an external fork first attempts to
  use private inputs, its base repo appears with Allow/Revoke controls.
- **Configure page** (`/configure`, sidebar → "Configure") — a self-host web UI
  to set a **default max build time** and **per-repo overrides** (each caps the
  eval and build phases *and* the pre-build nix commands — garnix-config eval,
  attribute discovery, flake metadata — so a wedged nix-daemon fails the push
  with a visible timeout instead of leaving it "Build starting" forever), plus
  quick links to each forge's webhook admin.
  Timeouts persist in `server_settings` / `repo_config.build_timeout_minutes`
  and are applied on top of the plan at build time (`/api/configure`). The
  synthetic self-host plan is otherwise unlimited on every dimension (CI
  minutes, PR-deploy minutes, server deployments, packages/flake, larger
  servers), surfaced on the plan page.
- **Gitea as a second forge** — an optional self-hosted [Gitea](https://about.gitea.com)
  instance alongside GitHub (both work at once). Push webhooks trigger builds and
  results report back as Gitea commit statuses. Off unless `giteaUrl` is set. See
  [the Gitea section](#optional-gitea-as-a-second-forge).
- **Monitoring page** (`/monitoring`, sidebar → "Monitoring") — a self-host
  dashboard of instance (Prometheus), configured builder (node-exporter), job,
  and deployment stats. Claimed guests receive a full control-plane stats
  endpoint; pre-warm
  guests cannot report before claim, and the ingestion route is guest-subnet
  gated. See [Monitoring](#monitoring).
- **SSH into deployed servers + extra ports** — `garnix.yaml` `servers[]` gains
  `exposeSSH` (public DNAT), `authorizeDeployerGithubKeys`, `authorizedSSHKeys`,
  and `ports`; reach guests via tailscale, ProxyJump, or DNAT, and expose extra
  http/tcp ports. Password auth is off, and direct human SSH to the guest's
  `garnix` user is closed until explicit human keys are delivered; the standing
  hosting key remains authorized for backend deploys. The Servers page also
  provides an authenticated browser terminal as `garnix` or any captured guest
  login user, using short-lived certificates from a dedicated SSH CA separate
  from the hosting/deploy key. See
  [SSH into a deployed server](#ssh-into-a-deployed-server-and-expose-extra-ports).
- **Configurable microVM size** — `deployment.machine` on each `servers[]` entry
  picks a tier (`i1x1`…`i16x32`, default `i1x1` = 1 vCPU / 1 GiB); see
  [Server deployments](#server-deployments-self-host-microvm-hosting).
- **Custom & vanity domains** — `garnix.yaml` `servers[].domains:` lets a
  hosted server answer on extra hostnames; operator wildcard bases
  (`services.garnixServer.extraHostingDomains`) and admin-registered
  connected domains (Configure page, DNS-points-here verify) both add more
  wildcard-covered bases, and the Servers-page **(i)** menu shows the exact
  DNS record for anything else. See
  [Custom & vanity domains](#custom--vanity-domains).
- **Self-host action runner** — `garnix.yaml` `actions` run in a local
  bubblewrap sandbox instead of upstream's runner fleet (`garnix.actionRunner`
  + `services.garnixServer.actionHost`). Required setup if you use actions —
  see [Actions](#actions-running-actions-on-a-self-host-runner).
- **Transactional local hosting** — the provisioner applies public exposure as
  an atomic compensating transaction, tears VMs down in dependency order, and
  keeps deploy-delivered guest keys in RAM-only tmpfs. See
  [Server deployments](#server-deployments-self-host-microvm-hosting).
- **Build artifacts** — `garnix.yaml` `artifacts:` publishes declared
  packages' build outputs as downloadable artifacts (file browser + `all.zip`,
  stable latest-URLs, content-addressed dedupe, retention/locking) — a GitHub
  Actions artifacts replacement. See [Artifacts](#artifacts).
- **sops made optional** — bring your own secrets manager (agenix, sops, plain
  files); the backend reads `/run/secrets/<name>` paths or env vars.
- **Operator-focused UI and docs** — inline status filters on Builds/Commit
  pages, inline repo/deploy/status filters on Servers, restart/cancel controls,
  and a hosted **Self-host fork** guide alongside the mirrored upstream docs.
- Single-host adaptations: no Hetzner fleet required (`buildMachines` for
  remote builders is optional), frontend/back-end/postgres/opensearch on one
  box behind one reverse proxy.

## Architecture

One NixOS host runs everything; only the reverse proxy listens publicly.

| Component | Port | Notes |
|---|---|---|
| backend (Haskell/Servant) | 8321 | `garnixServer.service`; loopback only |
| frontend (Next.js standalone) | 3000 | does **not** serve `/_next/static` — the proxy must |
| PostgreSQL | 9178 | TLS `verify-full`; also used at *compile* time by `postgresql-typed` |
| OpenSearch | 9200 | build-log search; fluent-bit ships logs into it |
| oauth2-proxy | 4180 | OIDC against your IdP; injects `X-Auth-Request-*` |
| Caddy (or nginx) | 443 | vhosts for UI/API, cache, webhooks |

Builds run in bubblewrap sandboxes on the host (plus any remote builders you
register). Build outputs are uploaded to two S3 buckets: a **public** one
(anonymous reads) and a **private** one (reads require a garnix access token
via netrc).

## Prerequisites

- A NixOS machine with flakes enabled and decent disk/CPU (it's a build box).
- Two DNS names pointing at it (`garnix.example.com`, `garnix-cache.example.com`).
- Two S3/B2 buckets (public-read + private) and credentials for each.
  On Backblaze: one key per bucket, since B2 keys can't scope to two buckets.
- An OIDC IdP (this guide assumes [Authentik](https://goauthentik.io)).
- A GitHub account/org for the GitHub App (created later from the admin page).

## Step 1 — Flake input and module

```nix
{
  inputs.garnix-ci.url = "github:joegoldin/garnix-ci-selfhosted";

  # in your host's modules:
  imports = [ inputs.garnix-ci.nixosModules.garnix ];
}
```

## Step 2 — Configure the server

```nix
{ config, lib, inputs, ... }: {
  services.garnixServer = {
    enable = true;
    url = "https://garnix.example.com";
    selfHostMode = true;
    adminGroup = "garnix-admins";        # proxy-injected group ⇒ admin
    # Must match X-Garnix-Proxy-Auth injected only after forward_auth.
    proxySharedSecretFile = "/run/secrets/garnix_proxy_shared_secret";
    githubAppName = "garnix-example";    # slug of the app you create in step 6
    modulesOrg = "youruser";             # org allowed to publish modules
    opensearchUrl = "http://[::1]:9200/_msearch";

    cacheUrl = "https://garnix-cache.example.com";
    cachePublicKey = "garnix-cache.example.com-1:<your cache signing pubkey>";

    # Point at your own buckets. mkForce: upstream hardcodes its fleet values.
    s3Cache = lib.mkForce {
      publicBucket = "example-garnix-cache-public";
      publicBaseUrl = "https://f000.backblazeb2.com/file/example-garnix-cache-public";
      privateBucket = "example-garnix-cache-private";
      host = "s3.us-west-000.backblazeb2.com";
      region = "us-west-000";
    };

    enableNginx = false;                 # we bring Caddy below
    maxLocalJobs = 8;                    # concurrent package builds
    maxConcurrentBuilds = 8;             # fair Garnix-side build queue
    maxRemoteFodJobs = 1;                # direct remote-store FOD sessions
    buildMachines = [ ];                 # optional remote builders (see step 10)

    # Optional: authenticate sandboxed builds to extra substituters (attic…).
    # Must be readable by the garnix service user (0440 root:garnix).
    buildNetRcFile = config.age.secrets.build-netrc.path;

    # Dedicated SSH CA used only for short-lived browser-terminal sessions.
    # The local provisioner must use this same key (its default path matches).
    terminalCaKeyPath = "/run/secrets/garnix_terminal_ca";
    # Optional but recommended: restrict terminal certs to this host-side
    # address on the guest bridge.
    terminalSourceAddress = "10.111.0.1/32";
  };

  # The host is the builder: emulate aarch64 + expose the features garnix wants.
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  nix.settings = {
    extra-platforms = [ "aarch64-linux" ];
    experimental-features = [ "nix-command" "flakes" "recursive-nix" ];
    system-features = [ "nixos-test" "benchmark" "big-parallel" "kvm" "recursive-nix" ];
    trusted-users = [ "garnix" ];
  };
}
```

## Step 3 — Secrets

The backend reads secrets from `/run/secrets/<name>` (or env vars). Provision
these with agenix/sops/whatever — **never** in the Nix store:

| Secret | Used for |
|---|---|
| `github-app-id`, `github-app-pk`, `github-client-id`, `github-client-secret`, `github-webhook-secret` | the GitHub App (created in step 6) |
| `s3-cache-access-key-id`, `s3-cache-secret-access-key` | public cache bucket |
| `s3-cache-private-access-key-id`, `s3-cache-private-secret-access-key` | private cache bucket (fork addition) |
| `cache-priv-key` | Nix cache signing key (`nix key generate-secret --key-name garnix-cache.example.com-1`) |
| `database-password` | postgres |
| `garnix-jwt-key` | session JWTs |
| `garnix_proxy_shared_secret` | Random proxy-provenance marker. The trusted gateway injects it as `X-Garnix-Proxy-Auth` only after successful authentication; the backend compares it with `proxySharedSecretFile` before trusting identity headers. |
| `opensearch-garnix` | opensearch auth |
| `repo-secrets-key`, `repo-secrets-key-pub` | age keypair for repo secrets |
| `garnix_action_runner_ssh` | SSH key the backend uses to reach the action runner (only if you run `actions` — see [Actions](#actions-running-actions-on-a-self-host-runner)). **Must be mode 0400** — OpenSSH rejects a group-readable key. |
| `garnix_terminal_ca` | Dedicated SSH CA private key used only to sign short-lived browser-terminal certificates. Keep it off guests and out of the Nix store; both the backend and local provisioner default to this path. |
| `s3-artifacts-public-access-key-id`, `s3-artifacts-public-secret-access-key`, `s3-artifacts-private-access-key-id`, `s3-artifacts-private-secret-access-key` | artifact buckets, one key pair each (only if you use `artifacts:` — see [Artifacts](#artifacts)) |

With agenix, the shape is:

```nix
age.secrets = builtins.mapAttrs (name: _: {
  file = ./secrets/${name}.age;
  path = "/run/secrets/${name}";   # where the backend expects them
  symlink = false;
  owner = "garnix"; group = "garnix"; mode = "0440";
}) { github-app-id = {}; /* … all of the above … */ };
```

⚠️ **Strip trailing newlines from every secret.** `jq -r` and most editors
append `\n`; GitHub rejects `client_secret\n` and S3 rejects
`Authorization has newlines`. Write secrets via stdin (`agenix -e x.age < f`).

## Step 4 — Reverse proxy (Caddy)

Two vhosts. Four rules are **security-critical**:

1. Strip inbound `X-Auth-Request-*` and `X-Garnix-Proxy-Auth` on every vhost.
2. Inject `X-Garnix-Proxy-Auth` into backend API requests **only after**
   `forward_auth` succeeds; its value must match `proxySharedSecretFile`.
3. The cache vhost must expose **only** `/api/cache` (never the whole backend —
   otherwise anyone can forge the groups header on the login endpoint and
   become admin);
4. Keep SSO bypasses narrow: webhooks are signature-verified, artifact/cache
   routes enforce their own access tokens, and guest stats are source-subnet
   gated. Everything else goes through the interactive gate.

```caddyfile
garnix.example.com {
  request_header -X-Auth-Request-User
  request_header -X-Auth-Request-Email
  request_header -X-Auth-Request-Groups
  request_header -X-Garnix-Proxy-Auth

  @webhook path /api/events/github/*
  handle @webhook { reverse_proxy 127.0.0.1:8321 }

  handle /oauth2/* { reverse_proxy 127.0.0.1:4180 }

  # Next.js standalone doesn't serve static assets; serve them from the pkg.
  handle /_next/* {
    root * {frontendPkg}/public
    file_server
  }

  handle {
    forward_auth 127.0.0.1:4180 {
      uri /oauth2/auth
      copy_headers X-Auth-Request-User X-Auth-Request-Email X-Auth-Request-Groups
      @error status 401
      handle_response @error { redir * /oauth2/start?rd={scheme}://{host}{uri} }
    }
    @api path /api/*
    reverse_proxy @api 127.0.0.1:8321 {
      # Read per request; grant the Caddy service user read access.
      header_up X-Garnix-Proxy-Auth {file./run/secrets/garnix_proxy_shared_secret}
    }
    reverse_proxy 127.0.0.1:3000
  }
}

garnix-cache.example.com {
  request_header -X-Auth-Request-User
  request_header -X-Auth-Request-Email
  request_header -X-Auth-Request-Groups
  request_header -X-Garnix-Proxy-Auth
  # Nix hits /nix-cache-info, /<hash>.narinfo, …; backend serves them under
  # /api/cache. The rewrite makes ONLY the cache surface reachable here.
  rewrite * /api/cache{uri}
  reverse_proxy 127.0.0.1:8321
}
```

(`{frontendPkg}` = `inputs.garnix-ci.packages.<system>.frontend_default`.)

## Step 5 — SSO gate (oauth2-proxy + Authentik)

In self-host mode the backend accepts proxy identity only when the request has
both `X-Auth-Request-Groups` and the private `X-Garnix-Proxy-Auth` marker whose
value matches `proxySharedSecretFile`. Loopback alone is not provenance: any
local process can connect to a loopback listener. The gateway must strip both
headers from clients, authenticate the request, then inject the marker only on
the authenticated backend hop. Missing marker configuration fails closed.

Authentik side:
1. Create an OAuth2/OIDC provider + application for
   `https://garnix.example.com/oauth2/callback`.
2. Gate access with **application entitlements** (not ad-hoc groups): create
   entitlements `garnixadmin` and `garnixuser` on the app, assign them to users.
3. Add a **scope mapping** that synthesizes a `groups` claim from entitlements,
   e.g.:

```python
entitlements = [e.name for e in request.user.app_entitlements(provider.application)]
groups = []
if "garnixadmin" in entitlements:
    groups += ["garnix-admins", "garnix-users"]
elif "garnixuser" in entitlements:
    groups += ["garnix-users"]
return {"groups": groups}
```

oauth2-proxy side (the hard gate is `allowed-group`):

```nix
services.oauth2-proxy = {
  enable = true;
  provider = "oidc";
  oidcIssuerUrl = "https://auth.example.com/application/o/garnix/";
  clientID = "<from authentik>";
  # client secret + cookie secret via keyFile
  scope = "openid profile email garnix";      # your scope-mapping's scope name
  redirectURL = "https://garnix.example.com/oauth2/callback";
  setXauthrequest = true;
  extraConfig = {
    "allowed-group" = "garnix-users,garnix-admins";
    "whitelist-domain" = "garnix.example.com";
    # Authentik may send email_verified=false:
    "insecure-oidc-allow-unverified-email" = true;
  };
};
```

## Step 6 — Deploy, then create the GitHub App

Deploy the host, then visit `https://garnix.example.com/garnix-admin` and use
the manifest flow ("Submit to GitHub") to create the App under your account.
Put the returned credentials into the secrets from step 3 (again: no trailing
newlines), redeploy, and **install the App** on the repos you want built.

Recommended App settings: disable *"Expire user authorization tokens"* —
garnix has no refresh-token flow, so 8-hour user tokens make GitHub-backed
pages (e.g. Servers) start returning 401 mid-day until re-login.

Then log in through the front page. If your Authentik user has the
`garnixadmin` entitlement, your account is a garnix admin.

## Step 7 — Pull from your cache on other machines

```nix
nix.settings = {
  extra-substituters = [ "https://garnix-cache.example.com" ];
  extra-trusted-public-keys = [ "garnix-cache.example.com-1:<pubkey>" ];
  netrc-file = "/run/secrets/garnix-netrc";  # for the private cache
};
```

netrc (create an access token under Account → Access Tokens):

```
machine garnix-cache.example.com
  login youruser
  password <access token>
```

Set `narinfo-cache-positive-ttl = 3600` — private paths are served with
presigned URLs that expire.

## Step 8 — Building your repos

Control what's built with `garnix.yaml` in each repo
([docs](https://garnix.io/docs/yaml_config)), e.g. build every host closure so
your machines just download instead of rebuilding:

```yaml
builds:
  include:
    - "nixosConfigurations.*"
```

**Fixed-output derivation (FOD) checks** (opt-in: `fodChecks: true` in
`garnix.yaml`) — on the selected checker store, garnix first realizes or
substitutes each FOD's baseline output, then rebuilds it while ignoring that
output so a lying hash surfaces in CI. This two-step sequence is required on
fresh self-hosted guests because Nix refuses `--rebuild` when the output is not
already valid in that store. A recognized source-fetch failure (dead mirror,
HTTP error, CDN blocking an automation user-agent) is reported as
skipped-with-warning because it proves nothing about the hash. Hash mismatches
and all unrecognized builder, Nix, SSH, or checker failures fail the run rather
than being mislabeled as source-unavailable. The conclusion is unambiguous:
**any FOD failed → failed**; nothing verified and every FOD was unfetchable →
**skipped** (a distinct grey conclusion, not a green pass); anything actually
verified (or known-good from a prior build) → **success**.

**Check conclusions map to the forge's native ones.** A run/check reports one of
`success`, `failure`, `timed out`, `cancelled`, or `skipped`. On GitHub these
become check-run conclusions (`success`/`failure`/`timed_out`/`cancelled`/`skipped`);
on Gitea the equivalent commit statuses (`skipped` is a real Gitea state as of
recent versions). `skipped` is non-blocking — treated as success for dependent
checks and the overall commit — but shown distinctly in the UI (a grey dash)
so an all-skipped check is never mistaken for a green pass.

**Only the latest commit matters?** Set `cancelSupersededBuilds: true` in
`garnix.yaml` and a new push to a branch cancels the still-queued/running
builds of older commits on that branch (PR-from-fork builds are untouched).
Off by default.

**Restarting and cancelling from the UI:** a commit page shows **Restart
failed** (re-runs each failed/timed-out build; if the eval itself failed, the
whole commit is re-run) and **Cancel all** (stops every queued/running build)
— both with confirmation. Cancelled builds render as an orange ✗, distinct
from red failures.

**Backend deploy/restart recovery:** after package evaluation succeeds, Garnix
stores the derivation and output map *before* starting FOD verification or
realization. On startup it resumes non-terminal build rows with that checkpoint
in place; packages from the same interrupted commit share one checkout,
authorization context, and replacement FOD coordinator. Re-running each
derivation joins or replaces the interrupted Nix work and preserves the
original row without creating a separate “FOD checks” run per package. A
concurrent user cancellation cannot be overwritten by the checkpoint. Work
interrupted before evaluation produced a derivation, plus action/deployment
`runs` whose external process cannot be reattached, is still marked Cancelled.
This is recovery from a process restart, not live migration of arbitrary
commands.

**Filtering busy instances:** the Builds-page status filter sits beside its
title; each Commit page has its own All/Active/Complete/Failed filter; and the
Servers page keeps repo, deployment-type, and status filters beside its title.
All three header groups wrap on narrow screens without separating the controls
from the page they filter.

**Triggering a branch build from the UI:** a repo's builds page has a **Trigger
Builds** button (next to _View on GitHub_) that opens a branch picker and runs a
fresh eval against the chosen branch's latest commit — handy for a first build,
or to re-run without pushing. Forge-aware: **GitHub** repos list every branch
live and the newest commit is resolved server-side; **Gitea** repos list the
branches garnix has already seen and re-run the latest commit it has for that
branch (there's no Gitea branch-list API wired up yet). Access is gated the same
as viewing the repo.

**Private flake inputs:** `git+ssh://` inputs can never work in CI (the sandbox
has no SSH key) — use `github:` refs; garnix injects its App token for those.
If a trusted push, branch, or same-owner fork has private `github:` inputs,
self-host mode injects the GitHub App token automatically and marks the base
repo `private_cache` before any upload. If the App installation cannot read an
input, the fetch fails normally and the build reports that real error.

An external fork is different: letting arbitrary fork code name any private
repo visible to a broadly installed GitHub App could expose that input through
build output. Its first attempt is therefore blocked and recorded. Only then
does the base repo appear under `/garnix-admin` → "External-fork private
inputs"; Allow permits a retry, Revoke restores the block, and either state
keeps every resulting closure in the authenticated cache. Private cache reads
require a cache-scope Garnix token whose GitHub login is a collaborator on the
base repo.

## Actions (running `actions` on a self-host runner)

`garnix.yaml` `actions:` run a nix app as a CI step (deploy scripts,
notifications, integration tests…). Unlike a build, an action's command is
**executed on a separate "action runner"**: the backend `nix copy`s the action
closure to `action-runner@<host>` and SSHes in to run it. Upstream points that
at its own runner fleet, so on a self-host box **actions stay Pending forever
until you stand up a local runner** (this is a required setup step if you use
`actions`). The fork's `action-runner` module does that, isolating each action
in a bubblewrap + slirp4netns sandbox on the garnix host itself.

In upstream managed mode, `sandboxType: shared-resources` is restricted to an
operator allowlist. In `selfHostMode`, that cloud allowlist is deliberately
bypassed: the self-host operator owns the runner and may use SharedResources
from any repository. This is separate from `modulesOrg`, which controls which
owner may publish Garnix modules (set it to your own user or organization).

1. **Secret.** Provision an SSH keypair as `garnix_action_runner_ssh` (see the
   secrets table). It **must be mode 0400** — OpenSSH refuses a group-readable
   private key. The backend connects with the private key; the runner
   authorizes its public key automatically (derived at boot), so no separate
   pubkey secret is needed.
   ```bash
   ssh-keygen -t ed25519 -N "" -C garnix-action-runner -f garnix-action-runner
   # then: agenix -e garnix_action_runner_ssh.age < garnix-action-runner
   ```
2. **Enable the runner** and point the backend at it:
   ```nix
   imports = [ "${garnix-ci}/nix/modules/action-runner.nix" ];
   garnix.actionRunner = {
     enable = true;
     # Derives + authorizes the pubkey of the key the backend connects with.
     sshPrivateKeyPath = "/run/secrets/garnix_action_runner_ssh";
   };
   services.garnixServer.actionHost = "127.0.0.1";   # SSH the runner locally
   # The key-derivation reads the installed secret — order it after your
   # secrets are in place (agenix/sops/…):
   systemd.services.garnix-action-runner-authorized-key.after = [ "agenix.service" ];
   ```
   The `action-runner` user is created for you, made a nix `trusted-user` (so
   `nix copy` works), and its authorized key is derived from the private key at
   boot. The backend reads the private key from `/run/secrets/garnix_action_runner_ssh`
   by default (override with the `GARNIX_ACTION_RUNNER_SSH_KEY` env var).
3. **Add an action** to a repo's `garnix.yaml` and push:
   ```yaml
   actions:
     - run: deploy          # apps.<system>.deploy — the nix app to execute
       on: push
   ```

Actions run as the unprivileged `action-runner` user, network-isolated via
slirp4netns (NAT, no host loopback), with a read-only `/nix` and a fresh
`/home`. `GARNIX_CI`, `GARNIX_BRANCH`, `GARNIX_COMMIT_SHA`, and the repo's
action key (`GARNIX_ACTION_PRIVATE_KEY_FILE`) are available to the command; add
`withRepoContents: true` to run the action **inside the checked-out repo**
(bound read-write at `/tmp/base`, which is also the working directory).
Actions that exceed their timeout report "The action took too long to complete
and it was cancelled." for every sandbox type, and the sandbox pins
`LC_ALL=C.UTF-8` so output ordering doesn't depend on the host locale.

### Ephemeral GitHub token for actions (`githubToken`)

Fetch-heavy actions that resolve `github:` flake inputs (e.g.
`github:NixOS/nixpkgs`) can hit GitHub's **60 requests/hour anonymous** rate
limit. Opt an action into a short-lived, scoped **GitHub App installation
access token** — minted per run and expiring in ~1 hour — with the per-action
`githubToken` flag (default off). garnix hands the token to the action as **both
a `GITHUB_TOKEN` environment variable and nix `access-tokens = github.com=…`**
(via `NIX_CONFIG`), so both `gh`/`curl`-style calls and nix's own `github:`
fetches authenticate — just like GitHub Actions' own `GITHUB_TOKEN`.

```yaml
actions:
  - run: my-action
    on: push
    githubToken: descoped   # none (default) | descoped | repo | repo-write
```

`githubToken` accepts a **string**, a **list of repo names**, or an **object**:

| Value | What garnix mints | Use it for |
| --- | --- | --- |
| `none` | Nothing (default). No token is set. | Actions that don't touch GitHub. |
| `descoped` | A token with **no permissions** (`permissions: {}`). It grants no repo access — it only authenticates the requester, lifting the rate limit to **5000/hr** for public data. | Fetching **public** `github:` inputs (nixpkgs, etc.). |
| `repo` | A token **scoped to this repo** with `contents: read`, like GitHub Actions' `GITHUB_TOKEN`. | Actions that read the current repo's contents via the GitHub API. |
| `repo-write` | This repo with `contents: write` (shorthand). | Actions that push to the current repo. |
| `[repo-a, repo-b]` | `contents: read` **scoped to exactly those repos** (short-names). | Actions that fetch/read several repos in the same org. |
| `{ repositories: [...], permission: read\|write }` | Full control. Both fields optional — `repositories` defaults to this repo, `permission` to `read`. | Anything the shorthands don't cover (e.g. write access to a list of repos). |

Listed repositories must all belong to the **same GitHub App installation**
(the org/user garnix is installed on); GitHub rejects the mint otherwise.

```yaml
# Examples
githubToken: [nixpkgs, my-lib]              # read those two repos
githubToken:
  repositories: [deploy-target]
  permission: write                          # write access to deploy-target
```

**GitHub-only.** On other forges (e.g. Gitea, which has no GitHub App
installation) `githubToken` is a no-op: nothing is minted and no token is set.
The token value is redacted from logs (`ghs_…` tokens are stripped, the same way
the checkout token is).

## Artifacts

`garnix.yaml` `artifacts:` publishes the build outputs of declared flake
packages as downloadable artifacts — a replacement for GitHub Actions
artifacts. Declared packages are **auto-included in builds**, so an
`artifacts:` entry alone is enough:

```yaml
artifacts:
  - package: web-skills-zips   # packages.<arch>.web-skills-zips
    name: claude-skills        # optional; defaults to the package name
```

On every successful build of the package, garnix walks the output
(dereferencing symlinks), uploads each file plus an `all.zip` and a
`manifest.json`, and the build page shows a file browser with per-file
downloads and a "Download .zip" link. Storage is **content-addressed** by the
output's store hash: builds whose output didn't change upload nothing and
share objects. Artifacts go to a public or private bucket by the same
repo-publicity rules as the cache.

**In the web UI.** A **View Artifacts** button (left of *Trigger Builds* on a
repo's builds page) opens a per-repo artifacts list with sizes, file counts, and
one-click `.zip` / manifest / browse-files downloads. Build-list rows show an
artifact icon + count for commits that produced artifacts, and each package /
check line on the commit page gets an artifact icon linking to that build's
downloads. All of this hides itself when the artifact store isn't configured.

**Setup:**

1. Two more S3/B2 buckets (public-read + private), separate from the cache
   buckets, with one key pair per bucket (again: B2 keys can't scope to two
   buckets).
2. Four secrets, readable by the garnix user (mode 0440; see the step-3 table):
   `s3-artifacts-public-access-key-id`, `s3-artifacts-public-secret-access-key`,
   `s3-artifacts-private-access-key-id`, `s3-artifacts-private-secret-access-key`.
3. Point the backend at the buckets (the feature is off when unset):
   ```nix
   services.garnixServer.s3Artifacts = {
     publicBucket = "example-garnix-artifacts-public";
     privateBucket = "example-garnix-artifacts-private";
     publicBaseUrl = "https://f000.backblazeb2.com/file/example-garnix-artifacts-public";
   };
   ```
   Host/region reuse the `s3Cache` values (same S3 account).
4. Bypass the SSO gate for downloads on the app vhost (next to the webhook
   bypass). Scripts fetch with garnix access tokens the proxy knows nothing
   about; the backend enforces session-or-token auth and repo access itself
   (public artifacts are anonymous by design):
   ```caddyfile
   @artifacts path /api/artifacts/*
   handle @artifacts { reverse_proxy 127.0.0.1:8321 }
   ```

**Stable "latest" URLs** resolve to the newest published artifact per
(repo, branch, name):

```
https://garnix.example.com/api/artifacts/<owner>/<repo>/<branch>/<name>/latest.zip
```

(also `.../latest/manifest` and `.../latest/files/<path>`; per-build URLs live
under `/api/artifacts/build/<buildId>/…`.) Public-repo artifacts download
anonymously — they 302 to the public bucket. Private ones need a session or an
access token with the `api` scope (Account → Access Tokens), passed as the
basic-auth password with your username as the login (netrc-compatible, same as
the cache — bare `Bearer` tokens aren't supported because tokens are stored
hashed per user):

```bash
curl -L -u youruser:<access token> \
  https://garnix.example.com/api/artifacts/youruser/myrepo/main/claude-skills/latest.zip \
  -o out.zip
```

**API reference** (all under `/api/artifacts`; branch segments URL-encode
slashes, e.g. `feature%2Ffoo`):

| Method | Path | What |
|---|---|---|
| GET | `/repo/<owner>/<repo>[?branch=]` | list a repo's artifacts (JSON) |
| GET | `/build/<buildId>` | list a build's artifacts (JSON) |
| GET | `/build/<buildId>/<name>/all.zip` | 302 → whole artifact as a zip |
| GET | `/build/<buildId>/<name>/manifest` | 302 → `manifest.json` (paths, sizes, sha256s, exec bits) |
| GET | `/build/<buildId>/<name>/files/<path>` | 302 → a single file |
| GET | `/<owner>/<repo>/<branch>/<name>/latest.zip` | newest published artifact, as a zip |
| GET | `/<owner>/<repo>/<branch>/<name>/latest/manifest` | newest artifact's manifest |
| GET | `/<owner>/<repo>/<branch>/<name>/latest/files/<path>` | a single file from the newest artifact |
| POST | `/build/<buildId>/lock` | lock the build's artifacts (admin) |
| DELETE | `/build/<buildId>/lock` | unlock (admin) |
| DELETE | `/<artifactId>` | delete an artifact row (admin; objects GC'd later) |

Retention settings live under `/api/configure`: the `GET` response carries
`artifact_retention_days`, `artifact_keep_latest`, `artifact_repo_overrides`,
`artifact_usage`, and `locked_artifact_builds`; write via
`PUT /api/configure/artifacts/default` and
`PUT`/`DELETE /api/configure/artifacts/repo/<owner>/<repo>`. The `garnix.yaml`
schema (including `artifacts:`) is served machine-readable at
`/api/config-schema` — the docs there are generated from the same codec that
parses the file.

**Retention.** Artifacts are reaped after a global default of **30 days**, set
on the Configure page along with per-repo overrides. Two exemptions:
**keep-latest** (default **off**; when on, the newest artifact per
repo/branch/name is never reaped — global default + per-repo override) and
per-build **locks** (toggled on the build page or the Configure page; a locked
build's artifacts are never reaped). Objects are garbage-collected once no
artifact row references them.

## Optional: Gitea as a second forge

garnix can integrate a self-hosted **Gitea** instance *alongside* GitHub — both
forges work simultaneously, and each repo is tagged with the forge it came from.
This is additive: leave `giteaUrl` unset and nothing changes.

**What's supported (MVP):** push webhooks → build → **commit-status** reporting.
Gitea has no check-runs API, so garnix posts commit statuses
(`POST /api/v1/repos/{owner}/{repo}/statuses/{sha}`): one `pending` when a run
starts, one terminal `success`/`failure`/`error`/`skipped` when it finishes,
each linking to the garnix build page. (`skipped` is a native Gitea commit-status
state in recent versions and is non-blocking, mirroring GitHub's `skipped`
conclusion.) Repo source is cloned from Gitea with the configured token;
publicity/collaborators are read from Gitea's API.

**Setup:**

1. In Gitea, create a **bot/admin account** and an **API token** (Settings →
   Applications) with access to the repos you want built. This single token
   authenticates all clone + API + status calls (Gitea has no per-repo
   installations like a GitHub App).
2. Provision two secrets on the garnix host (like the other garnix secrets):
   - `/run/secrets/gitea-token` — the API token
   - `/run/secrets/gitea-webhook-secret` — a random string you'll also put in the
     Gitea webhook config
   Both must be readable by the garnix server user; **strip trailing newlines**
   (a `\n` breaks the webhook HMAC and the bearer token).
3. Set the instance URL and deploy:
   ```nix
   services.garnixServer.giteaUrl = "https://gitea.example.com";
   ```
4. In each repo (or org), add a **webhook** in Gitea (Settings → Webhooks →
   Gitea):
   - Target URL: `https://garnix.example.com/api/events/gitea`
   - HTTP method: `POST`, Content type: `application/json`
   - Secret: the same value as `/run/secrets/gitea-webhook-secret`
   - Trigger on: **Push events** (branch push)
5. Add a `garnix.yaml` to the repo just like a GitHub repo. Push → build →
   commit status.

**How it works internally:** the backend serves `/api/events/gitea`, verifies
the `X-Gitea-Signature` HMAC-SHA256 over the raw body, parses Gitea's push
payload into the same `CommitInfo` the GitHub path uses, and runs the shared
build pipeline with a Gitea commit-status reporter. All forge-specific calls
(`getRemote`, repo publicity/collaborators, status reporting) dispatch on a
`Forge` tag; GitHub behaviour is unchanged.

**MVP limitations** (GitHub is unaffected by all of these):

- **Login** still uses GitHub OAuth for identity; in self-host mode access is
  gated by oauth2-proxy/Authentik regardless, and the Gitea webhook's sender is
  recorded as the build's requesting user — so builds work without Gitea login.
- **Private caches for Gitea repos**: a *public* Gitea repo's cache is served
  normally; a *private* Gitea repo's cache paths are currently fail-closed (not
  served), because the cache-serve permission check is GitHub-API-based. Public
  repos and the build/status loop are unaffected.
- **Private `github:` flake inputs from a Gitea repo** aren't supported (that
  would need a GitHub token the Gitea repo has no installation for); public
  `github:` inputs work fine.
- **Same `owner/name` on both forges collides** in the DB (builds are keyed on
  `owner/name` without a forge column yet) — don't mirror a repo under an
  identical path on both GitHub and Gitea.

## Step 9 — Multiple servers & hash subdomains (hosting)

Each deployed `nixosConfiguration` gets a unique URL derived from its config
hash — new version ⇒ new URL, zero-downtime cutover. Reference one hosted
server from another via `garnix-lib`'s `getHashSubdomain`, never a fixed name:

```nix
myservice.otherServiceURL =
  "http://" + garnix-lib.lib.getHashSubdomain self.nixosConfigurations.machine1;
```

## Server deployments (self-host microVM hosting)

Upstream deploys servers as Hetzner Cloud VMs. In self-host mode the same
deploy pipeline targets local [microvm.nix](https://github.com/microvm-nix/microvm.nix)
guests on the garnix host instead: a root daemon (`garnix-provisionerd`,
`provisioner/nixos-module.nix`) creates/destroys microVMs on a host-only
bridge (default `garnixbr0`, `10.111.0.0/24`, dnsmasq DHCP with per-MAC
reservations, NAT to your uplink), and the backend selects the local
provisioner whenever `services.garnixServer.provisionerSocket` is set. The
SSH deploy path is unchanged: `nix-copy-closure` into the guest, then
`switch-to-configuration switch`.

Destroy is idempotent and ordered: the daemon removes exposure, stops the VM
and its path-dependent tap/booted units, deletes the exact `gx<ID>` link, and
only then removes the VM/spec directories, gcroots, and dnsmasq state. This
keeps cleanup safe after partial creates and prevents deleted working
directories from breaking systemd `ExecStop` actions.

Exposure changes are transactional. Before mutating nftables state, the
provisioner validates the complete desired SSH/raw-TCP rule set and records the
current registry. Rule additions/removals and the atomic registry write form a
compensating transaction: a failure rolls back already-applied mutations in
reverse order, and a rollback failure reports both errors instead of hiding the
original cause. Port ranges are validated before any firewall change.

Host wiring (the fork stays input-free, so you import microvm.nix yourself):

```nix
imports = [
  "${garnix-ci}/provisioner/nixos-module.nix"
  microvm-nix.nixosModules.host
];
microvm.host.enable = true;
garnix.local-provisioner = {
  enable = true;
  uplinkInterface = "eno1";              # your default-route interface
  nixpkgsFlake = "path:${nixpkgs}";      # store-path pins: no network fetch
  microvmFlake = "path:${microvm-nix}";
  # Matches the backend's effective default CA path.
  terminalCaPrivateKeyPath = "/run/secrets/garnix_terminal_ca";
};
services.garnixServer = {
  hostingDomain = "apps.garnix.example.com";
  statsReportUrl = "https://garnix.example.com/api/hosts/stats";
  provisionerSocket = "/run/garnix-provisioner/provisioner.sock";
  provisionServerPool = true;            # pre-warm the pool (default: one i1x1)
};
```

Routing: deployed servers live at `<pkg>.<branch>.<repo>.<owner>.<hostingDomain>`
(primary deploys also at `<repo>.<owner>.<hostingDomain>`). Point a wildcard
DNS record `*.<hostingDomain>` (DNS-only, no proxy) at the host, run Traefik
against the backend's dynamic config, and front it with Caddy on-demand TLS —
per-SNI certs gated by `GET /api/hosts/on-demand-check?domain=`, which avoids
needing a wildcard cert for the two- and four-label app domains:

```nix
services.traefik = {
  enable = true;
  staticConfigOptions = {
    entryPoints.web.address = "127.0.0.1:8090";
    providers.http = {
      endpoint = "http://127.0.0.1:8321/api/hosts/traefik";
      pollInterval = "5s";
    };
  };
};
services.caddy.globalConfig = ''
  on_demand_tls {
    ask http://127.0.0.1:8321/api/hosts/on-demand-check
  }
'';
services.caddy.virtualHosts."https://".extraConfig = ''
  tls {
    on_demand
  }
  reverse_proxy 127.0.0.1:8090
'';
```

Guest contract: every deployed `nixosConfiguration` MUST import
`microvm.nixosModules.microvm` and `garnix-ci.nixosModules.garnix-guest`
(fixed volume/share/network conventions — 20 GiB root, 20 GiB writable store
overlay, virtiofs read-only store, DHCP) and set `garnix.guest.sshPublicKey`
to the instance's hosting public key (derived at service start into
`/var/lib/garnix-provisioner/hosting.pub`). Keep the `garnix-ci` input current:
the guest module must configure `TrustedUserCAKeys` with the durable terminal-CA
path described below. `garnix.guest.terminalCaPublicKey` defaults to
`sshPublicKey` only so repository flakes remain evaluable; the provisioner
injects the actual terminal-CA public key for first boot, and the backend owns
the durable copy after that. See
[`examples/hello-server/flake.nix`](examples/hello-server/flake.nix) for a
complete user repo.

The guest profile mounts `/var/garnix/keys` as tmpfs. Repo decryption keys,
default-Authentik credentials, and deploy-delivered authorized keys therefore
live only in RAM and are absent from the persistent root image. Because tmpfs
is empty after reboot, the backend re-delivers the runtime material during
claim/redeployment before activating the repository configuration. After a
standalone guest reboot, redeploy it before expecting services that consume
those runtime credentials to start successfully.

Pick a size per server with `deployment.machine` in `garnix.yaml` (default
`i1x1`); the tier name encodes `<vCPU>x<GiB>` and maps to guest resources
(20 GiB root + 20 GiB writable-store overlay for every tier):

```yaml
servers:
  - configuration: myServer
    deployment:
      branch: main
      machine: i2x4        # 2 vCPU, 4 GiB — omit for the i1x1 default
```

| tier              | vCPU | RAM (MiB) |
|-------------------|------|-----------|
| `i1x1` (default)  | 1    | 1024      |
| `i1x2`            | 1    | 2048      |
| `i2x2`            | 2    | 2048      |
| `i2x3`            | 2    | 3072      |
| `i2x4`            | 2    | 4096      |
| `i4x2`            | 4    | 2048      |
| `i4x4`            | 4    | 4096      |
| `i4x8`            | 4    | 8192      |
| `i8x8`            | 8    | 8192      |
| `i8x16`           | 8    | 16384     |
| `i16x16`          | 16   | 16384     |
| `i16x32`          | 16   | 32768     |

Enable pre-warming with `services.garnixServer.provisionServerPool`, then set
the exact available tiers with `services.garnixServer.serverPool` (for example,
`{ i2x4 = 1; }`). Each deployment's `machine` must match a pooled tier.

Deferred (documented, not implemented): guest IPv6 (recorded as `""`),
heartbeat-based reaping (disabled in self-host; deploys tear servers down),
and pool autostart across host reboots (the pool refills itself).

### SSH into a deployed server, and expose extra ports

`garnix.yaml` `servers[]` entries take four optional networking fields.
**Reachability** (`exposeSSH`) and **login authorization**
(`authorizeDeployerGithubKeys` / `authorizedSSHKeys`) are independent — you
usually want both:

```yaml
servers:
  - configuration: myServer
    deployment:
      branch: main
      machine: i2x2
    # Reachability: open a public DNAT port forwarding to the guest's :22.
    # This does NOT grant login by itself.
    exposeSSH: true
    # Login: authorize the deployer's github.com/<user>.keys on the garnix user.
    authorizeDeployerGithubKeys: true
    # Login: authorize extra explicit keys on the garnix user.
    authorizedSSHKeys:
      - "ssh-ed25519 AAAA... me@laptop"
    # Extra ports. `http` -> a Traefik subdomain; `tcp` -> a raw host port.
    ports:
      - { name: api, port: 8080, type: http }
      - { name: db,  port: 5432, type: tcp }
```

**Hardened by default.** Password authentication is disabled
(`PasswordAuthentication no`, `KbdInteractiveAuthentication no`) and root is
key-only. The `garnix` account always authorizes the operator-controlled hosting
key in NixOS's managed key file so the backend can activate configurations,
redeploy, and discover login accounts after activation. It has **no human
authorized keys** unless you set `authorizeDeployerGithubKeys: true` and/or list
`authorizedSSHKeys`; those opt-ins write
`/var/garnix/keys/authorized_keys` at deploy time. The authenticated browser
terminal is separate: its short-lived terminal-CA certificate may log in as
`garnix` or another account captured from the guest. Once human keys are
authorized, three direct-SSH routes are shown with copyable commands on the
**Servers** page:

- **Tailscale** — advertise the guest subnet from the host
  (`services.tailscale.useRoutingFeatures = "server"` +
  `--advertise-routes=10.111.0.0/24`, approved in the tailnet admin), then
  `ssh garnix@<internal-ip>` directly (no `exposeSSH` needed).
- **ProxyJump** — `ssh -J <host> garnix@<internal-ip>`, jumping through the
  garnix host (`services.garnixServer.sshHost`).
- **DNAT** — with `exposeSSH: true`, the provisioner opens a deterministic
  public host port (`sshExposePortBase + id%1000`); `ssh -p <port> garnix@<host>`.

**Bring your own login user (fully manual).** If you'd rather not touch the
`garnix` user, declare an ordinary login user in the deployed
`nixosConfiguration` — same pattern as
[garnix-io/user-module](https://github.com/garnix-io/user-module) — and use
`exposeSSH: true` (or tailscale) purely for reachability:

```nix
users.users.me = {
  isNormalUser = true;
  extraGroups = [ "wheel" ];
  openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... me@laptop" ];
};
```

**Extra ports.** `http` ports are served at `<name>.<pkg>.<branch>.<repo>.<owner>.<hostingDomain>`
via Traefik (on-demand TLS issues for them automatically). `tcp` ports get a
public host port via DNAT (`tcpExposePortBase + id*20 + i`); the host:port is
shown on the Servers page. Set `services.garnixServer.sshHost` and the
provisioner's `exposePortRange` (firewall) for the DNAT methods.

### Redeploy, and the in-browser terminal

Each row on the **Servers** page has, alongside Visit / Delete / Logs / Monitor:

- **Redeploy** — kicks off a fresh build+deploy job for the server's current
  commit (`POST /api/hosts/<id>/redeploy`, auth + ownership-gated). It re-runs
  the whole pipeline (`Orchestrator.restartCommit`), so it rebuilds and
  redeploys; works for both branch and PR deployments.
- **Open Terminal** — an in-browser shell to the guest, at
  `/servers/<id>/terminal`. A websocket endpoint (`/api/terminal/<id>`) attaches
  a PTY running SSH to the guest IP resolved from the DB, never from the client.
  Each connection gets a throwaway key and a 61-minute user certificate signed
  by the dedicated terminal CA; the CA private key never leaves the garnix
  host. It is authenticated (JWT/cookie), repo-access checked, requires the
  server to be `Online`, and is hardened: fixed command (no client-supplied
  host/args/options), declared non-root login users only, no port/agent/X11
  forwarding, an `Origin` allowlist, a 10-minute idle / 60-minute absolute
  timeout, and a per-user concurrency cap. Terminal bytes are never logged.
  **The endpoint must stay behind your authenticated reverse-proxy gate** —
  never bypass-list `/api/terminal`; see
  [`docs/web-terminal.md`](docs/web-terminal.md).

**Login user.** The terminal defaults to the `garnix` user, but the "Login as"
picker lets you switch. Its suggestions are the real login accounts on the guest:
at deploy time garnix reads them from the machine (`getent passwd`, minus
`nologin`/`false` shells) over the SSH session it already opens to switch
configuration, and stores them on the server (`servers.ssh_users`, surfaced as
`ssh_users`). You can also type any username; it is validated
(`^[a-z_][a-z0-9_-]{0,31}$`) on both sides and passed as a single
non-interpolated `user@ip` argument. The backend only signs a certificate when
the account was captured from that guest (with `garnix` as the built-in deploy
user), always refuses `root`, and scopes the certificate to the chosen login
principal.

#### Terminal CA handoff, upgrades, and rotation

Generate a CA key separately from the standing hosting/deploy key, deliver its
private half only to the garnix host, and point both
`services.garnixServer.terminalCaKeyPath` and
`garnix.local-provisioner.terminalCaPrivateKeyPath` at it. The backend fails
closed when the private key is absent; it never falls back to signing terminal
certificates with the hosting key.

The public half crosses into a guest through a compensating transaction:

1. On first boot, the provisioner injects the public key and the guest profile
   seeds `/var/lib/garnix/terminal-ca.pub`.
2. Before every initial activation and persistent redeployment, the backend
   derives the public key from its configured private key and installs it at
   that durable path over the existing hosting SSH channel.
3. Only after that write succeeds does garnix activate the repository-built
   configuration. A failed handoff fails the deployment instead of activating
   a guest that the browser terminal cannot authenticate to.
4. The guest module points OpenSSH `TrustedUserCAKeys` at the durable `/var/lib`
   file, so repository activation and guest reboot do not erase the trust root.

When upgrading an existing deployment to this design, bump the `garnix-ci`
flake input in every hosted repository and redeploy its servers. Updating only
the backend/provisioner does not change a repository-locked guest module that
still points sshd at the old `/etc` path.

To rotate the terminal CA, replace the private key on the garnix host and
restart the backend and provisioner, then redeploy every online server. The
redeploy refreshes the durable public key before activation. New browser
terminal connections to a not-yet-redeployed guest will fail after the backend
starts signing with the new CA; existing SSH sessions are unaffected. For a
no-gap rotation, preinstall the new public key on every guest through the
hosting SSH channel **alongside the old public key** (the file accepts multiple
CA lines) before restarting the backend. Redeployment then replaces the
transition file with the new public key alone.

### Custom & vanity domains

`garnix.yaml` `servers[]` entries take an optional `domains:` list — extra
hostnames a deployed server answers on, alongside its default
`<pkg>.<branch>.<repo>.<owner>.<hostingDomain>` address:

```yaml
servers:
  - configuration: myServer
    deployment: { branch: main }
    domains:
      - myapp.example.dev      # vanity, under a known hosting base
      - app.example.com      # bare custom domain
```

Each declared name is checked against the known **hosting bases** — the
default `hostingDomain`, any operator `extraHostingDomains`, and any verified
**connected domain** (below). A name under a base is wildcard-covered: garnix
adds a `Host(...)` router and an on-demand-TLS allow-entry, no DNS action
needed. A name under **no** base is a bare custom domain — point it at garnix
yourself with an `A` record to the host's IP or a `CNAME` to a garnix domain
(the (i) menu below tells you which).

**Operator wildcard bases.** `services.garnixServer.extraHostingDomains` (a
list of strings) adds vanity bases beyond the default `hostingDomain`, e.g.
`[ "example.dev" "example.app" ]` — each needs its own manual wildcard DNS record,
`*.<domain>` → the host, same as `hostingDomain`'s. Also set
`services.garnixServer.hostingPublicIp` to the host's public IP so the (i)
menu can render exact `A`-record instructions for bare custom domains;
without it, the menu only offers the CNAME-to-a-garnix-domain option (fine
for subdomains — apex domains need the IP).

**Connected domains (Configure page, admin-only).** The page lists both
Nix-configured wildcard bases and domains registered at runtime. Every row
shows its DNS status; unverified rows have a **Verify** button, while verified
rows keep their successful status across restarts and no longer show the
button. Nix-configured rows are read-only. To add another domain without
touching Nix, register it, point its DNS at garnix (`A`, `CNAME`, or a wildcard
record, as appropriate), then click **Verify**. Verification is a
**DNS-points-here** check — an A/wildcard lookup confirming the domain already
resolves to the host — not a TXT token or ownership challenge. Once a
registered domain is verified, it joins the known bases above, so any
`servers[].domains` entry under it becomes wildcard-covered with no further
DNS changes.

**Servers page (i) menu.** Each running server's controls include an **(i)**
button listing its declared domains and, per domain, the exact record to set
(`A` → the hosting IP, or `CNAME` → the default base) plus a live "resolves
here yet?" status, using the same DNS-points-here check as Verify.

### Monitoring

A self-host-only **Monitoring** page (sidebar, between Modules and
Documentation) aggregates, via `GET /api/monitoring`:

- **Instance** — garnix's own Prometheus (`services.garnixServer.metricsScrapeUrl`,
  default `127.0.0.1:<metricsPort>/` — the endpoint serves at the root path):
  queue depths, builds attempted, cache-push ratio.
- **Builders** — every target in `services.garnixServer.monitoringBuilders`,
  with its supported systems, `maxJobs`, load, memory, disk, and CPU count.
  Targets are scraped concurrently, so an unavailable builder is marked as
  such without hiding healthy builders or the rest of the page. When the list
  is empty, the legacy `services.garnixServer.nodeExporterUrl` remains the
  single-host fallback.
- **Jobs** — running/pending builds + actions/deploys and recent build durations.
- **Deployments** — the live servers (from `/api/hosts`).

Each server's **Monitor** view adds a rolling CPU/memory history reported by
the guest. A pre-warm guest contains the reporter but no activation marker, so
it cannot report before the backend has claimed it. During claim the backend
writes the non-secret endpoint and VM id to the durable
`/var/lib/garnix/stats.env`; the shared guest module consumes that file after
repository activation and on later reboots. Configure the backend's full
control-plane endpoint with `services.garnixServer.statsReportUrl` (or
`GARNIX_STATS_REPORT_URL`); never derive it from the workload
`hostingDomain`. The reporter accepts only 2xx responses and surfaces redirects
or HTTP errors in `garnix-stats-reporter.service`. Keep `/api/hosts/stats`
outside the interactive-login gate; the backend independently restricts it to
the guest bridge source subnet.

Set `services.garnixServer.serverPool` to the machine tiers deployments may
claim. For example, `{ i2x4 = 1; }` keeps one 2-vCPU/4-GiB guest warm; the
deployment must request the same tier with `deployment.machine = "i2x4"`.
Unlisted tiers have no warm guests and cannot be claimed.

When upgrading an existing deployment, update the repository's `garnix-ci`
flake input and redeploy it once. The backend refreshes `stats.env` before the
configuration switch, so the updated guest module starts reporting without VM
recreation; subsequent redeploys also pick up endpoint changes automatically.

### Locking a deployed server behind Authentik (or any OIDC provider)

`garnix-ci.nixosModules.garnix-authentik` gates a deployed server behind an
OIDC login with one import: it runs `oauth2-proxy` plus an nginx forward-auth
gate on port 80 (the port Traefik proxies to), so every request needs a valid
session before it reaches your service. Point your own service at a different
port and set `garnix.authentik.upstream` to it.

**Fastest path — reuse garnix's own login (`mode = "default"`):** put
`authentik: default` on the server's `garnix.yaml` entry and garnix drops its
*own* OIDC client credentials (plus this deployment's redirect URL) onto the
guest at deploy time — no provider setup, no client id, no secret in the repo.
Whoever can log into garnix can reach the app. Ideal for dev deployments.

```yaml
servers:
  - configuration: hello
    deployment:
      type: on-branch
      branch: main
    authentik: default
```

```nix
garnix.authentik = {
  enable = true;
  mode = "default";
  upstream = "127.0.0.1:8080";   # your service (NOT on :80)
};
```

Requirements (one-time, on the garnix host): set
`services.garnixServer.defaultAuthentik = { issuerUrl, clientId,
clientSecretFile }` to garnix's own OIDC client, and allow the deployed
servers' callback URLs on that Authentik provider (Authentik supports regex
redirect URIs — e.g. `^https://[a-z0-9-]+\.[a-z0-9-]+\.[a-z0-9-]+\.[a-z0-9-]+\.apps\.garnix\.example\.com/oauth2/callback$`).

**Dedicated / shared providers** (own app per deployment, or one shared app
gated by claims — see `docs/authentik-cookbook.md`):

```nix
modules = [
  microvm.nixosModules.microvm
  garnix-ci.nixosModules.garnix-guest
  garnix-ci.nixosModules.garnix-authentik
  {
    garnix.guest.sshPublicKey = "<YOUR HOSTING PUBLIC KEY>";
    garnix.authentik = {
      enable = true;
      publicUrl = "https://app.main.myrepo.myorg.apps.example.com";
      issuerUrl = "https://authentik.example.com/application/o/myapp/";
      clientId = "<oidc client id>";
      allowedGroups = [ "my-app-users" ];   # omit to allow any logged-in user
      upstream = "127.0.0.1:8080";           # your service (NOT on :80)
      # age ciphertext of the OIDC client secret, encrypted to this repo's
      # public key. Safe to commit; decrypted at runtime on the guest.
      clientSecretAge = ''
        -----BEGIN AGE ENCRYPTED FILE-----
        ...
        -----END AGE ENCRYPTED FILE-----
      '';
    };
    services.myApp.port = 8080;              # your actual app, behind the gate
  }
];
```

The client secret is delivered the garnix-native way: encrypt it to the repo's
public key (`GET /api/keys/<owner>/<repo>/repo-key.public`, or via `age -r`),
paste the ciphertext into `clientSecretAge`, and the guest decrypts it at
runtime with the repo private key garnix drops at `/var/garnix/keys/repo-key`
(root-only). No plaintext secret ever lands in the world-readable nix store.
The cookie secret is generated on the guest and persisted. `oauth2-proxy` only
trusts forwarded headers from the loopback nginx gate. This module doubles as a
worked example when writing your own custom garnix server modules.

## Step 10 — Remote builders (optional)

```nix
services.garnixServer.buildMachines = [{
  hostName = "mac-builder.tailnet.example";
  sshUser = "nix-ssh";
  sshKey = "/run/secrets/builder-ssh-key";
  systems = [ "aarch64-darwin" "x86_64-darwin" ];
  maxJobs = 4; speedFactor = 1;
  supportedFeatures = [ "big-parallel" ];
}];

# Direct FOD checker sessions bypass the Nix scheduler, so cap them separately.
# A 2-core/12-GiB builder should normally stay at one.
services.garnixServer.maxRemoteFodJobs = 1;

# Optional operator monitoring for the local and remote builders.
services.garnixServer.monitoringBuilders = [
  {
    name = "local";
    url = "http://127.0.0.1:9100/metrics";
    systems = [ "x86_64-linux" ];
    maxJobs = 8;
  }
  {
    name = "arm-builder";
    url = "http://arm-builder.example:9100/metrics";
    systems = [ "aarch64-linux" ];
    maxJobs = 1;
  }
];
```

`buildMachines[*].maxJobs` limits ordinary builds scheduled by the Nix daemon.
FOD verification uses `nix --store` directly so it can prepare and strictly
rebuild on one specific store; those sessions are instead limited by
`maxRemoteFodJobs` (default `1`) and transient SSH transport failures are
retried with jittered backoff. The cap queues work in Garnix instead of opening
too many simultaneous SSH sessions against a small builder.

Remote node-exporters should never be internet-wide. Bind the exporter only
as broadly as needed and enforce a source allowlist at both the host firewall
and the service boundary (for example, the control-plane host's stable `/32`
plus the Tailscale CGNAT range). Do not add port 9100 to a global
`allowedTCPPorts` list.

Until a darwin builder is registered, exclude `darwinConfigurations.*` from
your `garnix.yaml` includes.

## Step 11 — Keep CI from eating the machine

The heavy work happens in the `nix-daemon` cgroup (derivation builds) and the
`garnixServer` cgroup (evals, nar packing, uploads). Example: cap to half of a
20-thread/256G box:

```nix
nix.settings.cores = lib.mkForce 10;          # per-derivation threads
systemd.services.nix-daemon.serviceConfig = {
  CPUQuota = "1000%";                          # 10 of 20 threads total
  MemoryHigh = "115G"; MemoryMax = "125G";
};
services.garnixServer.maxLocalJobs = 8;
```

### Concurrency & log-shipping under load

A single push fans out one build per package / `nixosConfiguration`; several
pushes in quick succession — or bumping a shared flake input that rebuilds
everything — can mean dozens of concurrent guest builds all streaming logs at
once. These controls keep that from swamping the box or the log pipeline:

- **`services.garnixServer.maxConcurrentBuilds`** (default `16`) caps how many
  builds *run* at once. Every build is still created and reported as a pending
  check immediately — the cap only queues the actual eval+build, so nothing is
  dropped, work just paces itself. Queued work is scheduled **round-robin
  across repos, FIFO within a repo**: one repo's giant fan-out can't monopolize
  the slots, and within a repo the oldest job always runs first. Evals are
  separately capped at 32. Sets `GARNIX_MAX_CONCURRENT_BUILDS`. The
  `garnix_server_*_queue_len` gauges report the number of *waiters* (0 while
  slots are free).
- **`services.garnixServer.maxRemoteFodJobs`** (default `1`) caps direct
  remote-store FOD sessions. This is separate from each build machine's
  `maxJobs`, because the FOD checker deliberately targets a store with
  `--store` and therefore bypasses the Nix daemon scheduler. Sets
  `GARNIX_FOD_REMOTE_MAX_JOBS`.
- Build logs ship best-effort from the server to a local fluent-bit HTTP input,
  then to OpenSearch. Under a heavy wave fluent-bit's default 128-slot accept
  backlog can saturate and silently drop lines (an empty **Logs** panel on a
  *finished* build is the tell). The input now runs `Threaded` with a 1024-deep
  `net.backlog`, and drops are counted in `garnix_server_log_ship_failures_total`
  (plus a rate-limited journal warning) instead of vanishing.

Pressure is visible in Prometheus: `garnix_server_build_queue_len` /
`garnix_server_build_queue_wait_time` (builds waiting for a slot),
`garnix_server_eval_queue_len`, and `garnix_server_log_ship_failures_total`.

## Step 12 — Backups

Postgres (builds/users/config + the cache index) is the state that matters;
OpenSearch is rebuildable and the cache NARs already live in S3. Example:
`services.postgresqlBackup` dumps every 6h, restic ships dumps + raw build
logs to another bucket nightly, with a weekly `--read-data-subset=5%` check:

```nix
services.restic.backups.b2 = {
  repository = "s3:https://s3.us-west-000.backblazeb2.com/example-garnix-backups/bigbox";
  environmentFile = "/run/secrets/restic-env";   # bucket credentials
  passwordFile = "/run/secrets/restic-password";
  initialize = true;
  paths = [ "/var/backup/postgresql" "/var/lib/garnix/logs" ];
  timerConfig = { OnCalendar = "03:30"; RandomizedDelaySec = "15m"; Persistent = true; };
  pruneOpts = [ "--keep-daily 7" "--keep-weekly 4" "--keep-monthly 6" ];
};
```

Run a restore drill before trusting it (`restic-b2 restore latest --target /tmp/drill`).

## Gotchas learned the hard way

| Symptom | Cause / fix |
|---|---|
| Build "failed with no output" | eval/authorization failed before building — grep the commit sha in `journalctl -u garnixServer` |
| `Header Authorization has newlines` | trailing `\n` in an S3 secret |
| "Github didn't give us a user token" | trailing `\n` in the GitHub client secret |
| White page, `/_next` 404s | proxy must serve `/_next/*` from the frontend package |
| `getInstalledOrgs … 401` | expired 8h user token — re-login; disable token expiry on the App |
| Jobs interrupted by a `garnixServer` restart (deploy) | package builds checkpoint their derivation immediately after evaluation and are resumed on startup; work interrupted before that checkpoint, plus action/deployment run processes that cannot be reattached, is marked Cancelled. If pushes sit at "Build starting" with *no* restart involved, the pre-build nix commands are wedged (they'll fail with a `NixCommandTimeout` once the configured cap fires) — check the nix-daemon |
| every eval hangs; plain `nix` commands block on the host | nix-daemon deadlock — for us it was `min-free`/`max-free` **auto-GC** deadlocking on `gc.lock` against a concurrent `addToStore`. Don't run auto-GC on the garnix host; use a scheduled `nix-collect-garbage` job instead, and if it happens find the fork holding the `gc.lock` flock in `/proc/locks` and kill it |
| **Logs** panel empty on a *finished* build | log-shipping to fluent-bit dropped the lines (best-effort) — usually a mass build wave saturating its accept backlog. Check `garnix_server_log_ship_failures_total` and `journalctl -u garnixServer \| grep 'fluent-bit writer'`. Mitigated by `maxConcurrentBuilds` + the 1024 backlog |
| `cabal build` fails with `Network.Socket.connect` | `postgresql-typed` typechecks SQL against a live pg at compile time — build via `nix build .#backend_garnixHaskellPackage` (its sandbox spins one up) |
| nix build: `can't find source for <new file>` | new files must be `git add`ed before a git-flake build sees them |
| 401s from your private substituter inside builds | set `buildNetRcFile` (the sandbox can't read the host's root-only netrc) |
| every FOD is skipped as “source unavailable” with `--rebuild and --check error if the derivation was not previously built` | the checker store was fresh and lacked the baseline output; prepare/substitute the FOD on that same store before the strict `--rebuild`. Do not classify this Nix precondition error as a fetch failure |

---

# Upstream development docs

## Running Garnix locally in VMs

You can spin up a couple of qemu VMs that provide a full Garnix deployment with:

```bash
nix run -L .#examples_spinUpVms
```

This will use [`nixos-compose`](https://github.com/garnix-io/nixos-compose).
If you run:

```bash
nixos-compose tap
nixos-compose status
```

You should then be able to point your browser to the ip address of the `exampleGarnixServer` to see the hosted ci.

And there's an admin page on `/garnix-admin` that is useful for some development tasks.

### Setting up a GitHub app

You _will_ need a github app for Garnix to work, both for production and for testing.
On the `/garnix-admin` page you can create one by pressing the 'Submit to GitHub' button.
That will give you a bunch of credentials that you'll have to put into the `/secrets/dev.yaml` file by running

```bash
sops edit secrets/dev.yaml
```

Then you have to enable your new GitHub app on a repo that you want to build through the GitHub ui.
Finally, you can submit a test build, with something like this:

```bash
curl -v \
  -XPOST \
  http://$(nixos-compose ip exampleGarnixServer)/api/build/submit \
  -H 'Content-Type: application/json' \
  -d '{ "owner": "garnix-io", "repo": "comment", "testCommit": "8b2b57d91dd1f4d094bb944a0a0ef65319a5663f" }'
```

And then you can see the build under `/repo/garnix-io/comment`, for example.

### Developing the frontend

You can run the frontend in development mode against a backend in a VM like this:

```bash
nixos-compose up -v
cd frontend
npm run dev
```

Then point your browser to [localhost:3000](http://localhost:3000).

### Running the backend test suite

CI runs the full suite as the `backend_specs` action on every push (~35–40 min;
tests tagged `@skip-ci` in their name are skipped there). Locally, give each
run a throwaway Postgres dir — reusing a shared `pg-tmp` across runs leaves
zombie postgreses that break the next run:

```bash
nix develop --command bash -c '
  set -e
  DB_DIR=$(mktemp -d /tmp/specdb.XXXXXX)
  export DB_DIR PGDATA=$DB_DIR/test PGHOST=$DB_DIR/test \
         TPG_HOST=$DB_DIR/test TPG_SOCK=$DB_DIR/test/.s.PGSQL.9178
  db new
  cd backend
  cabal run spec -- --match "<substring>" --skip @skip-ci
  db clear; rm -rf $DB_DIR'
```

Every failure prints its exact `--match` rerun line; multiple `--match` flags
union. Notes: the deploy specs boot real qemu VMs (KVM strongly recommended)
via the provisioner mock, and the Action specs boot
`nixosConfigurations.action-runner2` (`nix/tests/action-runner-vm.nix`);
`SpecHook` fixes up the committed test SSH keys' permissions at suite start
(git can't store 0600 modes).


# Acknowledgments

We erased git history when open sourcing, so we'll be explicit here about our
debt to everyone who contributed before the project became open source:

- Alex David
- Evie Ciobanu
- Greg Pfeil
- Jean-François Roche
- Julian Kirsten Arni
- Ramses de Norre
- Sönke Hahn

Thanks very very much!
