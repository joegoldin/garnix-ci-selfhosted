# Cookbook: gate garnix-hosted apps behind Authentik

This walks through putting a garnix-deployed server behind Authentik login using
`garnix-ci.nixosModules.garnix-authentik`, and — the important part — using
**Authentik application entitlements** so you control *which users get which
apps*.

## Zero-setup: `authentikDefault` (reuse garnix's own login)

For "put this behind *my* login, now" — dev deployments, personal tools — skip
providers entirely: set `garnix.server.authentikDefault = true;` in the
deployed configuration and set `garnix.authentik = { enable = true; mode =
"default"; upstream = "127.0.0.1:<port>"; }` alongside it. garnix drops its
own OIDC client credentials (and the deployment's redirect URL) onto the
guest at deploy time; access is exactly "whoever can log into garnix".
Requires `services.garnixServer.defaultAuthentik` on the garnix host and a
redirect-URI allowance for `https://*.<hostingDomain>/oauth2/callback` on
garnix's own Authentik provider (regex redirect URI). For per-app access
control, use the dedicated/shared modes below instead.

## Two ways to map apps onto Authentik

`garnix.authentik.mode` picks how a deployment relates to Authentik. The runtime
gate (oauth2-proxy + nginx forward-auth) is identical; only the Authentik-side
setup differs.

| | `mode = "dedicated"` (default) | `mode = "shared"` |
|---|---|---|
| Authentik object | its **own** application + provider | reuses **one existing** provider/app |
| Shows in Authentik as | its own app (clean per-app UX) | just the shared app |
| Secret | its own clientId + client secret | shared clientId/secret (no new secret) |
| Access control | the app's **entitlement bindings** | a per-app **scope's claim** (mandatory) |
| Adding an app costs | a new provider + app + secret | one more **scope mapping** on the shared provider |

**Dedicated is the ideal** — each app is a first-class Authentik application you
can entitle independently. **Shared** is the lightweight path: set up one
provider once (with a regex redirect URI), then each new app is just another
scope mapping — no new secrets to mint or encrypt. Both are covered below, and
the `authentik-provision` helper (§0) automates either.

## 0. Automate it: the `authentik-provision` helper

Instead of clicking through the Authentik UI, drive its REST API:

```sh
# dedicated: token + entitlement both defaulted. Creates a provider + app + the
# "hello-locked-user" entitlement -> "hello-locked-users" group, writes the
# encrypted secret file, and prints the config block.
nix run github:joegoldin/garnix-ci-selfhosted#provisioner_authentikProvision -- \
  --authentik-url https://authentik.example.com \
  --name hello-locked \
  --public-url https://hello-locked.main.myrepo.myorg.apps.example.com \
  --repo-pubkey-url https://garnix.example.com/api/keys/myorg/myrepo/repo-key.public

# shared: reuse an existing provider "garnix-shared"; extra role shown explicitly
nix run github:joegoldin/garnix-ci-selfhosted#provisioner_authentikProvision -- --mode shared \
  --provider garnix-shared \
  --authentik-url https://authentik.example.com \
  --name reports \
  --entitlement reports-user=reports-users \
  --entitlement reports-admin=reports-admins \
  --public-url https://reports.main.myrepo.myorg.apps.example.com \
  --repo-pubkey-url https://garnix.example.com/api/keys/myorg/myrepo/repo-key.public
```

It creates the provider/application (dedicated) or extends the existing provider
(shared), creates the **application entitlements** and a **scope mapping** that
reads `request.user.app_entitlements(provider.application)` (see §2/§3),
**writes the client secret to a committed `.age` file** (encrypted to the repo's
public key, default `<name>-client-secret.age`), and prints a ready-to-paste
`garnix.authentik = { … };` block on stdout that references that file by path —
no inline ciphertext. Progress notes go to stderr.

Defaults that keep the command short:

- **API token** — read from `/run/agenix/authentik-api-token` by default (see
  [§6](#6-store-the-authentik-api-token-in-agenix)); override with `--token-file`,
  `--token`, or `$AUTHENTIK_TOKEN`.
- **`--entitlement`** — defaults to `<name>-user=<name>-users`; pass it
  (repeatable) to add roles, e.g. `--entitlement reports-admin=reports-admins`.
- **`--repo-pubkey-url`** — the garnix repo-key endpoint is **public** (no login,
  works for private repos too — it only exposes the *public* key, which can
  encrypt but not decrypt), so this always resolves.

The sections below describe what the helper does, so you can also do it by hand.

## How the pieces fit

```
browser ──TLS──> Caddy (host, on-demand cert)
                   └─ reverse_proxy ─> Traefik (host)
                        └─ ─> guest:80  nginx forward-auth gate ┐
                                          │  (garnix-authentik)  │
                                          ├─ /oauth2/* ─────────> oauth2-proxy :4180 ─OIDC─> Authentik
                                          └─ everything else: auth_request ─> :4180/oauth2/auth
                                                on 2xx ─> your service (upstream)
                                                on 401 ─> redirect to Authentik login
```

Two independent gates decide access:

1. **Authentik application entitlements** — *who may log into this app at all.*
   Authentik refuses to complete the OIDC flow for a user with no entitlement,
   so they never get a session. This is the primary, per-app control.
2. **`garnix.authentik.allowedGroups`** (optional) — a defense-in-depth claim
   check inside oauth2-proxy. Leave it empty to let Authentik's entitlements be
   the sole gate.

## 1. Create the OIDC provider + application in Authentik

For each app you want to protect:

1. **Providers → Create → OAuth2/OpenID Provider**
   - Name: `myapp`
   - Authorization flow: your default `authorization_flow` (implicit consent is
     fine for first-party apps)
   - Client type: **Confidential**
   - Redirect URIs: `https://<pkg>.<branch>.<repo>.<owner>.apps.<your-domain>/oauth2/callback`
     (the app's garnix URL + `/oauth2/callback`)
   - Signing key: your default
   - Note the generated **Client ID** and **Client Secret**.
2. **Applications → Create**
   - Name: `MyApp`, slug `myapp`
   - Provider: the provider from step 1
   - The OIDC **issuer URL** is then
     `https://<authentik-host>/application/o/myapp/` — this is `issuerUrl`.

## 2. Control access with application entitlements

Authentik **application entitlements** are named grants on an application (e.g.
`garnixadmin`, `garnixuser`, or per-app `myapp-user`). You bind users/groups to
an entitlement, and a **scope mapping** reads which entitlements the logged-in
user holds for the app (`request.user.app_entitlements(provider.application)`)
and turns them into group names in the token. This is the exact pattern the
`authentik-provision` helper creates, and what the garnix "garnix groups"
mapping does.

1. Open the app's **Application entitlements** tab (preview; Authentik 2024.8+).
2. **Create entitlement** → e.g. `myapp-user`, and bind the users/groups who may
   use the app to it.
3. The scope mapping in §3 reads these and emits a group; oauth2-proxy gates on
   that group (`allowedGroups`). A user with no matching entitlement gets no
   group and is refused (403).

The helper creates the entitlement objects for you; you still bind members to
them in Authentik.

## 3. Emit a groups claim from the app entitlements

Turn the user's entitlements for this app into a `groups` claim (this is what the
helper generates — the garnix "garnix groups" mapping is the canonical example):

1. **Customization → Property Mappings → Create → Scope Mapping**
   - Name: `myapp groups`, Scope name: `myapp`
   - Expression:
     ```python
     entitlement_names = {
         e.name for e in request.user.app_entitlements(provider.application)
     }
     groups = []
     if "myapp-user" in entitlement_names:
         groups.append("myapp-users")
     return {"groups": groups}
     ```
2. Add that scope mapping to the provider's **Selected Scopes**.
3. In your deployed config, request the scope and gate on the claim:
   ```nix
   garnix.authentik = {
     scope = "openid profile email myapp-entitlements";
     groupsClaim = "groups";          # the claim your mapping emits
     allowedGroups = [ "myapp-users" ];
   };
   ```
   `oidc-groups-claim` / `allowed-group` in oauth2-proxy then reject anyone whose
   token doesn't carry `myapp-users`.

## 4. Deliver the client secret (no plaintext in the repo)

The guest already holds the repo's age private key at `/var/garnix/keys/repo-key`.
Encrypt the OIDC client secret to the repo's **public** key into a committed
`.age` file, and reference it by path (never inline ciphertext):

```sh
# fetch the repo public key garnix generated
curl -s https://<your-garnix>/api/keys/<owner>/<repo>/repo-key.public > repo.pub

# encrypt the client secret into a .age file you commit
mkdir -p secrets
printf %s '<oidc client secret>' | age -R repo.pub -a > secrets/myapp-client-secret.age
# → reference it by path: clientSecretFile = ./secrets/myapp-client-secret.age;
```

The `.age` file is copied into the store (still encrypted) and decrypted at
runtime; the plaintext never enters the nix store.

## 5. Wire it in the deployed config

```nix
modules = [
  garnix-ci.nixosModules.garnix-guest
  garnix-ci.nixosModules.garnix-authentik
  {
    garnix.authentik = {
      enable = true;
      publicUrl = "https://myapp.main.myrepo.myorg.apps.example.com";
      issuerUrl = "https://authentik.example.com/application/o/myapp/";
      clientId = "<client id>";
      clientSecretFile = ./secrets/myapp-client-secret.age;   # committed .age file
      allowedGroups = [ "myapp-users" ];   # omit to let entitlements be the only gate
      upstream = "127.0.0.1:8080";
    };
    services.myApp = { enable = true; port = 8080; };   # your service, behind the gate
  }
];
```

Push to your deploy branch; garnix builds and deploys the guest. Hitting the
app's URL now bounces you through Authentik, and only entitled users get in.

## Bypassing the gate for token-authenticated paths

Some endpoints can't do the OIDC dance — API/webhook clients that authenticate
with their own bearer token and can't follow a browser redirect to Authentik.
`garnix.authentik.skipAuthPaths` proxies declared path prefixes straight to
`upstream`, with no `auth_request` gate, so the app's own token check is the
only thing guarding them:

```nix
garnix.authentik = {
  enable = true;
  publicUrl = "https://myapp.main.myrepo.myorg.apps.example.com";
  issuerUrl = "https://authentik.example.com/application/o/myapp/";
  clientId = "<client id>";
  clientSecretFile = ./secrets/myapp-client-secret.age;
  upstream = "127.0.0.1:8080";
  skipAuthPaths = [ "/mcp" ];   # e.g. an MCP endpoint hit by bearer-token clients
};
```

Each entry becomes an nginx prefix location covering the path and everything
under it (`/mcp` also matches `/mcp/anything`), proxying to the same upstream
as the authenticated catch-all. Entries must start with `/`, and can't be `/`
itself or start with `/oauth2` — either would blow a hole in the gate or break
the OIDC callback flow; the module asserts this. Only bypass paths whose
handler enforces its own authentication — anything else is reachable by
anyone who can route to the guest.

## Header-based SSO to the app

Once a request has passed the auth_request gate, your app usually doesn't
need its own login screen — it can just read who's logged in from a header
and trust it. `garnix.authentik.forwardIdentityHeaders` (**default `true`**)
forwards the verified identity from oauth2-proxy's auth subrequest
(`setXauthrequest = true` sets these as response headers on `/oauth2/auth`) to
`upstream` as:

- `X-Auth-Request-User`
- `X-Auth-Request-Email`
- `X-Auth-Request-Preferred-Username`
- `X-Auth-Request-Groups`

```nix
garnix.authentik = {
  enable = true;
  publicUrl = "https://myapp.main.myrepo.myorg.apps.example.com";
  issuerUrl = "https://authentik.example.com/application/o/myapp/";
  clientId = "<client id>";
  clientSecretFile = ./secrets/myapp-client-secret.age;
  upstream = "127.0.0.1:8080";
  # forwardIdentityHeaders = true;  # default — set false to withhold identity
};
```

**Trust model:** the gate sets these headers with an *unconditional*
`proxy_set_header` on every proxied request, so even if a client sends its own
`X-Auth-Request-User: admin`, the value nginx forwards is always the one it
just read from the auth subrequest — the client's header is discarded, not
merged. Your app should only read these headers as trusted identity when it
*knows* it's deployed behind this gate (i.e. it never listens anywhere else,
or it's on a private network reachable only via the gate) — if the same app
binary can also be reached directly, bypassing nginx, these headers become
attacker-controlled again. `skipAuthPaths` locations blank all four headers
unconditionally, regardless of `forwardIdentityHeaders`, since those requests
never go through the auth subrequest and have no verified identity to
forward. Set `forwardIdentityHeaders = false` if your app has its own login
and should not see (or accidentally trust) these headers.

## Shared mode: one provider, many apps

If you'd rather not mint a provider + secret per app, run everything through a
single shared Authentik application and distinguish apps by a per-app scope.

**Set up the shared provider once:**

1. Create one OAuth2/OpenID provider (**Confidential**) and application, exactly
   as in §1 — call it e.g. `garnix-shared`.
2. Note the shared **clientId**, **client secret**, and **issuer**
   (`https://<authentik-host>/application/o/garnix-shared/`).

The helper adds each app's redirect URI to the shared provider automatically
(strict, i.e. the app's exact callback; pass `--redirect-mode regex` for a
single catch-all like `^https://[^/]+\.apps\.example\.com/oauth2/callback$` so
you never edit the provider again).

**For each app, add just a scope mapping** (§3 style) named for the app, e.g.
scope name `reports`, plus one or more **application entitlements** on the shared
app (e.g. `reports-user`) that the mapping keys off:

```python
entitlement_names = {
    e.name for e in request.user.app_entitlements(provider.application)
}
groups = []
if "reports-user" in entitlement_names:
    groups.append("reports-users")
return {"groups": groups}
```

Add the mapping to the shared provider's **Selected Scopes**, bind users to the
`reports-user` entitlement, and gate the deployment on the claim:

```nix
garnix.authentik = {
  enable = true;
  mode = "shared";
  publicUrl = "https://reports.main.myrepo.myorg.apps.example.com";
  issuerUrl = "https://authentik.example.com/application/o/garnix-shared/";  # the SHARED app
  clientId = "<shared client id>";
  clientSecretFile = ./secrets/reports-client-secret.age;   # the SHARED secret, encrypted to THIS repo's key
  scope = "openid profile email reports";  # the app's scope
  groupsClaim = "groups";
  allowedGroups = [ "reports-users" ];   # REQUIRED in shared mode — the only per-app gate
  upstream = "127.0.0.1:8080";
};
```

In shared mode the module **asserts** that `scope` is customized and
`allowedGroups` is non-empty: because the shared app admits anyone entitled to
it, the scope's claim check is the sole thing keeping `reports` and `payroll`
apart. The same shared secret is reused everywhere — you still encrypt it to each
repo's key (each repo has its own repo-key), which the helper does for you.

## 6. Store the Authentik API token in agenix

So the helper's token isn't in your shell history or environment, keep it as an
agenix secret readable by your user:

1. Add a rule in `dotfiles-secrets/secrets.nix` (the `users` list already keys
   secrets to your personal + workstation keys):
   ```nix
   "authentik-api-token.age".publicKeys = users;
   ```
2. Create/encrypt it (opens `$EDITOR`; paste the token, save):
   ```sh
   cd ~/Development/dotfiles-secrets
   agenix -e authentik-api-token.age
   ```
3. Expose it on your workstation (e.g. torrent) so it decrypts to
   `/run/agenix/authentik-api-token`, owned by you:
   ```nix
   age.secrets.authentik-api-token = {
     file = "${inputs.dotfiles-secrets}/authentik-api-token.age";
     owner = meta.username;
     mode = "0400";
   };
   ```
4. Point the helper at it: `--token-file /run/agenix/authentik-api-token`.

## Gotchas

- **Redirect URI must match exactly**, including the full multi-label garnix
  host and `/oauth2/callback`.
- Your service must listen on `upstream` (e.g. `127.0.0.1:8080`), **not** `:80`
  — the module owns `:80` for the gate.
- Authentik often issues `email_verified=false`; the module sets
  `insecure-oidc-allow-unverified-email` so that doesn't 500 the callback. If
  you enforce email verification in Authentik you can drop it.
- Cookie sessions reset when a guest is recreated (redeploys provision a fresh
  microVM) — expected for ephemeral hosting.
- **The cookie secret must be URL-safe, unpadded base64** (43 chars → 32 bytes).
  oauth2-proxy decodes it with Go's `base64.RawURLEncoding` and falls back to the
  literal string on failure, so standard `base64` output becomes a 44-byte key
  and the process exits with `cookie_secret must be 16, 24, or 32 bytes to
  create an AES cipher, but is 44 bytes`. The module handles this; only relevant
  if you write your own generator. Because ~74% of random secrets contain a `+`
  or `/`, getting it wrong presents as *intermittent* deploy failures.
- **Debugging a gated deploy that fails activation**: the failure surfaces as
  `exit 4` from `switch-to-configuration`, and the whole generation rolls back,
  so the guest is gone before you can inspect it. The deploy log on the Servers
  page carries `systemctl status` plus each failed unit's full journal — read
  that rather than trying to catch the guest. Verify a fix with one request: a
  working gate 302s to `/oauth2/start` and follows through to the Authentik
  login flow.
  ```bash
  curl -sSL -o /dev/null -w '%{http_code} %{url_effective}\n' \
    https://<pkg>.<branch>.<repo>.<owner>.<appsDomain>/oauth2/start
  ```
- See [`examples/hello-server/flake.nix`](../examples/hello-server/flake.nix)
  for the `hello-locked` configuration using this module end-to-end.
