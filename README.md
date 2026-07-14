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
    `X-Auth-Request-Groups`; membership of `adminGroup` ⇒ garnix admin;
  - public repos may depend on **private flake inputs**: the guard auto-allows
    it and routes that repo's store paths to the **authenticated** cache bucket
    so nothing private leaks via the public cache.
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
- **Admin API + UI** (`/garnix-admin` → "Per-repo config", `/api/admin/repo-config`)
  for per-repo overrides (`skip_private_inputs_check`, `private_cache`).
- **Gitea as a second forge** — an optional self-hosted [Gitea](https://about.gitea.com)
  instance alongside GitHub (both work at once). Push webhooks trigger builds and
  results report back as Gitea commit statuses. Off unless `giteaUrl` is set. See
  [the Gitea section](#optional-gitea-as-a-second-forge).
- **sops made optional** — bring your own secrets manager (agenix, sops, plain
  files); the backend reads `/run/secrets/<name>` paths or env vars.
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
  inputs.garnix-ci.url = "github:joegoldin/garnix-ci/self-hosting";

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
    buildMachines = [ ];                 # optional remote builders (see step 10)

    # Optional: authenticate sandboxed builds to extra substituters (attic…).
    # Must be readable by the garnix service user (0440 root:garnix).
    buildNetRcFile = config.age.secrets.build-netrc.path;
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
| `opensearch-garnix` | opensearch auth |
| `repo-secrets-key`, `repo-secrets-key-pub` | age keypair for repo secrets |

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

Two vhosts. Three rules are **security-critical**:
1. strip inbound `X-Auth-Request-*` on every vhost (only `forward_auth` may set them);
2. the cache vhost must expose **only** `/api/cache` (never the whole backend —
   otherwise anyone can forge the groups header on the login endpoint and
   become admin);
3. webhooks and the cache bypass SSO, everything else goes through it.

```caddyfile
garnix.example.com {
  request_header -X-Auth-Request-User
  request_header -X-Auth-Request-Email
  request_header -X-Auth-Request-Groups

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
    reverse_proxy @api 127.0.0.1:8321
    reverse_proxy 127.0.0.1:3000
  }
}

garnix-cache.example.com {
  request_header -X-Auth-Request-User
  request_header -X-Auth-Request-Email
  request_header -X-Auth-Request-Groups
  # Nix hits /nix-cache-info, /<hash>.narinfo, …; backend serves them under
  # /api/cache. The rewrite makes ONLY the cache surface reachable here.
  rewrite * /api/cache{uri}
  reverse_proxy 127.0.0.1:8321
}
```

(`{frontendPkg}` = `inputs.garnix-ci.packages.<system>.frontend_default`.)

## Step 5 — SSO gate (oauth2-proxy + Authentik)

In self-host mode the backend trusts `X-Auth-Request-Groups` as the sole
authority for who may log in and who is admin — safe because it listens on
loopback and the proxy strips the header from clients.

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

**Private flake inputs:** `git+ssh://` inputs can never work in CI (the sandbox
has no SSH key) — use `github:` refs; garnix injects its App token for those.
If a **public** repo has **private** `github:` inputs, self-host mode allows it
automatically and routes that repo's closures to the private (authenticated)
bucket. Override per-repo on `/garnix-admin` → "Per-repo config".

## Optional: Gitea as a second forge

garnix can integrate a self-hosted **Gitea** instance *alongside* GitHub — both
forges work simultaneously, and each repo is tagged with the forge it came from.
This is additive: leave `giteaUrl` unset and nothing changes.

**What's supported (MVP):** push webhooks → build → **commit-status** reporting.
Gitea has no check-runs API, so garnix posts commit statuses
(`POST /api/v1/repos/{owner}/{repo}/statuses/{sha}`): one `pending` when a run
starts, one terminal `success`/`failure`/`error` when it finishes, each linking
to the garnix build page. Repo source is cloned from Gitea with the configured
token; publicity/collaborators are read from Gitea's API.

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
```

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
| Jobs stuck "Pending" forever | orphaned by a `garnixServer` restart (deploy) mid-build; cancel them |
| `cabal build` fails with `Network.Socket.connect` | `postgresql-typed` typechecks SQL against a live pg at compile time — build via `nix build .#backend_garnixHaskellPackage` (its sandbox spins one up) |
| nix build: `can't find source for <new file>` | new files must be `git add`ed before a git-flake build sees them |
| 401s from your private substituter inside builds | set `buildNetRcFile` (the sandbox can't read the host's root-only netrc) |

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
