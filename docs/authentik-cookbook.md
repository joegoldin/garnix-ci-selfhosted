# Cookbook: gate garnix-hosted apps behind Authentik

This walks through putting a garnix-deployed server behind Authentik login using
`garnix-ci.nixosModules.garnix-authentik`, and — the important part — using
**Authentik application entitlements** so you control *which users get which
apps*.

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
# dedicated: create a fresh provider + app, gate on a group, encrypt the secret
nix run github:joegoldin/garnix-ci#provisioner_authentikProvision -- \
  --authentik-url https://authentik.example.com \
  --token-file /run/agenix/authentik-api-token \
  --name hello-locked \
  --public-url https://hello-locked.main.myrepo.myorg.apps.example.com \
  --repo-pubkey-url https://garnix.example.com/api/keys/myorg/myrepo/repo-key.public \
  --group hello-locked-users

# shared: add a per-app scope mapping to an existing provider named "garnix-shared"
nix run github:joegoldin/garnix-ci#provisioner_authentikProvision -- --mode shared \
  --provider garnix-shared \
  --authentik-url https://authentik.example.com \
  --token-file /run/agenix/authentik-api-token \
  --name reports \
  --public-url https://reports.main.myrepo.myorg.apps.example.com \
  --repo-pubkey-url https://garnix.example.com/api/keys/myorg/myrepo/repo-key.public \
  --group reports-users
```

It creates the provider/application (dedicated) or the scope mapping + regex
redirect (shared), ensures the group, age-encrypts the client secret to the
repo's public key, and prints a ready-to-paste `garnix.authentik = { … };` block
on stdout (progress notes go to stderr).

Get an API token from Authentik (**Directory → Tokens**, or a service account),
and store it in agenix so it's not on your shell history — see
[§6](#6-store-the-authentik-api-token-in-agenix). The helper reads it from
`--token-file`, `--token`, or `$AUTHENTIK_TOKEN`.

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

This is how you get "user A sees app X, user B sees app Y":

1. Open the **Application → Entitlements** tab (Authentik 2024.8+; on older
   versions use **Bindings** on the application's Policy/Group/User bindings).
2. **Create binding** → bind a **Group** (e.g. `myapp-users`) or individual
   **Users** to the application.
3. Only bound users can complete login for this app. A user who is not bound
   gets an Authentik "not authorized to access this application" page — they
   never reach your service.

Make one group per app (`myapp-users`, `otherapp-users`, …) and add users to
the groups that match the apps they should see. Access is now pure group
membership managed in Authentik.

## 3. (Optional) Emit a groups/entitlements claim for `allowedGroups`

If you want a second gate inside oauth2-proxy (or you can't rely on entitlement
bindings), have Authentik put the user's groups into the token:

1. **Customization → Property Mappings → Create → Scope Mapping**
   - Name: `myapp-groups`, Scope name: `myapp-entitlements`
   - Expression:
     ```python
     return { "groups": [g.name for g in request.user.ak_groups.all()] }
     ```
     (or map from entitlements if you use them as the source of truth)
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
Encrypt the OIDC client secret to the repo's **public** key and commit the
ciphertext:

```sh
# fetch the repo public key garnix generated
curl -s https://<your-garnix>/api/keys/<owner>/<repo>/repo-key.public > repo.pub

# encrypt the client secret to it
printf '%s' '<oidc client secret>' | age -R repo.pub -a
# → paste the -----BEGIN AGE ENCRYPTED FILE----- block into clientSecretAge
```

The guest decrypts it at runtime; the plaintext never enters the nix store.

## 5. Wire it in the deployed config

```nix
modules = [
  microvm.nixosModules.microvm
  garnix-ci.nixosModules.garnix-guest
  garnix-ci.nixosModules.garnix-authentik
  {
    garnix.guest.sshPublicKey = "<YOUR HOSTING PUBLIC KEY>";
    garnix.authentik = {
      enable = true;
      publicUrl = "https://myapp.main.myrepo.myorg.apps.example.com";
      issuerUrl = "https://authentik.example.com/application/o/myapp/";
      clientId = "<client id>";
      clientSecretAge = ''-----BEGIN AGE ENCRYPTED FILE-----
        ...
        -----END AGE ENCRYPTED FILE-----'';
      allowedGroups = [ "myapp-users" ];   # omit to let entitlements be the only gate
      upstream = "127.0.0.1:8080";
    };
    services.myApp = { enable = true; port = 8080; };   # your service, behind the gate
  }
];
```

Push to your deploy branch; garnix builds and deploys the guest. Hitting the
app's URL now bounces you through Authentik, and only entitled users get in.

## Shared mode: one provider, many apps

If you'd rather not mint a provider + secret per app, run everything through a
single shared Authentik application and distinguish apps by a per-app scope.

**Set up the shared provider once:**

1. Create one OAuth2/OpenID provider (**Confidential**) and application, exactly
   as in §1 — call it e.g. `garnix-shared`.
2. Give its provider a **regex redirect URI** so every garnix app host is
   covered without editing it again. In **Providers → garnix-shared → Redirect
   URIs**, add a `regex` entry:
   ```
   ^https://[^/]+\.apps\.example\.com/oauth2/callback$
   ```
   (the helper adds this for you on the first shared app).
3. Note the shared **clientId**, **client secret**, and **issuer**
   (`https://<authentik-host>/application/o/garnix-shared/`).

**For each app, add just a scope mapping** (§3 style) named for the app, e.g.
scope name `reports-entitlements`, emitting the user's groups under a claim:

```python
return {"groups": [group.name for group in request.user.ak_groups.all()]}
```

Add it to the shared provider's **Selected Scopes**, and gate the deployment on
the claim:

```nix
garnix.authentik = {
  enable = true;
  mode = "shared";
  publicUrl = "https://reports.main.myrepo.myorg.apps.example.com";
  issuerUrl = "https://authentik.example.com/application/o/garnix-shared/";  # the SHARED app
  clientId = "<shared client id>";
  clientSecretAge = ''-----BEGIN AGE ENCRYPTED FILE-----
    ...
    -----END AGE ENCRYPTED FILE-----'';   # the SHARED secret, encrypted to THIS repo's key
  scope = "openid profile email reports-entitlements";  # the app's scope
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
- See [`examples/hello-server/flake.nix`](../examples/hello-server/flake.nix)
  for the `hello-locked` configuration using this module end-to-end.
