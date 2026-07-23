# Web terminal (`/servers/<id>/terminal`)

The web UI can open an interactive shell on a deployed server: the page at
`/servers/<id>/terminal` runs xterm.js in the browser and connects a
websocket to the backend at

```
GET /api/terminal/<serverId>   (websocket upgrade)
```

On the backend (`Garnix.API.Terminal`) the connection:

1. must carry an authenticated garnix **web session** (the same
   `Auth '[JWT, Cookie]` as the rest of the API — cookie or
   `Authorization: Bearer`); anything else is rejected with 401 before any
   upgrade,
2. must reference a server **owned by that user** (the exact
   `getRunningAndRecentServersForOwners` membership check that
   `GET /api/hosts/<id>/stats` and `DELETE /api/hosts/<id>` use); otherwise
   404; the user must also pass the server repository's normal access check,
   and the server must be Online,
3. if a browser `Origin` header is present it must equal the configured
   `GARNIX_URL` origin (cross-site WebSocket hijacking defense; browsers
   always send `Origin` on ws handshakes), otherwise 403.

Only then does the backend create a throwaway Ed25519 keypair and sign its
public key with the dedicated terminal CA. The 61-minute certificate is scoped
to the selected, guest-declared non-root login user (plus a per-server
principal), clears SSH certificate extensions, and restores only `permit-pty`.
When configured, its `source-address` constraint pins authentication to the
backend's address on the guest bridge. The CA private key remains on the garnix
host and the throwaway keypair is removed when the session ends.

A PTY is then attached to a **fixed argv** — `ssh` with that certificate and
the deploy path's connection/host-key arguments, forwarding fully disabled
(`ClearAllForwardings=yes`, no agent/X11 forwarding, `BatchMode=yes`,
`IdentitiesOnly=yes`) — to `<login-user>@<guest ip>`. The guest IP is resolved
**from the database row**, never from the client. The client can only send
terminal bytes and (clamped) resize dimensions. The hosting/deploy key is not a
certificate authority; terminal certificates are signed only by the dedicated
CA.

Sessions are bounded: at most 4 concurrent sessions per user, a 10-minute
idle timeout and a 60-minute absolute limit; on every exit path the ssh
child is TERMed, the PTY master closed (HUP) and, if needed, KILLed.
Terminal content is never written to logs — lifecycle events only.

## What the operator must configure

The security model assumes the endpoint sits behind the same reverse-proxy
auth gate as the rest of `/api`. Concretely:

### Dedicated terminal CA

Generate a dedicated SSH CA keypair and expose only its private-key file to the
backend and local provisioner. Do not reuse the hosting/deploy key and do not
put the CA private key in a flake, guest, or Nix store path.

```sh
ssh-keygen -q -t ed25519 -N '' -C garnix-terminal-ca \
  -f garnix_terminal_ca
```

Install the private file with permissions readable by the corresponding
services, then configure the same path on both sides:

```nix
services.garnixServer = {
  terminalCaKeyPath = "/run/secrets/garnix_terminal_ca";
  # Optional but recommended: the host's address on the guest bridge.
  terminalSourceAddress = "10.111.0.1/32";
};
garnix.local-provisioner.terminalCaPrivateKeyPath =
  "/run/secrets/garnix_terminal_ca";
```

The provisioner option defaults to `/run/secrets/garnix_terminal_ca`; when
`terminalCaKeyPath` is null, the backend uses that same effective default. If
the backend cannot read the key, opening a terminal fails closed; it never
signs with the hosting key as a fallback.

### Guest trust and durable handoff

Every deployed repository configuration must import the current
`garnix-ci.nixosModules.garnix-guest`. The module configures:

```text
TrustedUserCAKeys /var/lib/garnix/terminal-ca.pub
AuthorizedPrincipalsFile /var/lib/garnix/terminal-principals
```

The public key reaches that durable path in two stages. The provisioner's
first-boot profile injects the actual CA public key and seeds the file. Before
every initial activation and persistent redeployment, the backend derives the
public key from its configured private key and installs it as `root:root` mode
`0644` over the existing hosting SSH channel. Over that same channel it also
installs `/var/lib/garnix/terminal-principals` containing this server's
`server-<hash>` principal; with `AuthorizedPrincipalsFile` set, sshd accepts a
certificate only if it carries that principal, so a certificate minted for one
server cannot authenticate on another (per-user restriction stays enforced at
mint time by the backend). Existing guests must be recreated to gain the
principals file. Garnix activates the
repository-built configuration only after this write succeeds. Consequently,
repository activation and guest reboot preserve terminal trust, while the CA
private key never enters the guest.

`garnix.guest.terminalCaPublicKey` defaults to
`garnix.guest.sshPublicKey` for repository-flake evaluation compatibility, and
the fork supplies a neutral default hosting public key. Operators of another
instance must override `sshPublicKey` with their provisioner's public key. Do
not treat the terminal-CA fallback as the deployed trust source: the
provisioner supplies the real first-boot value and the backend refreshes the
durable file. Existing hosted repositories must bump their `garnix-ci` lock and
redeploy once so their guest configuration points sshd at the durable path;
updating only the host services cannot rewrite a stale repository-locked guest
module.

### CA rotation

After replacing the CA private key, restart the backend and provisioner and
redeploy every online server. Each redeploy installs the new public key before
activation. Between the backend restart and a guest's redeploy, new browser
terminal connections to that guest fail because it still trusts the old CA;
existing SSH sessions continue. To avoid that gap, preinstall the new public
key at `/var/lib/garnix/terminal-ca.pub` on every guest **alongside the old
public key** (the file accepts multiple CA lines) through the hosting SSH
channel before restarting the backend. Redeployment then replaces the
transition file with the new public key alone.

### Self-host behind Caddy + oauth2-proxy (Authentik)

The recommended self-host front (a `forward_auth` catch-all with explicit
bypass matchers for webhooks/public keys/badges/artifacts/stats) already
gates `/api/terminal/*`, because the endpoint deliberately has **no bypass
matcher**. The requirements are:

* **Never add `/api/terminal` to any bypass/`handle` block that skips
  `forward_auth`.** It must fall through to the authenticated catch-all:

  ```caddyfile
  # ... @webhook/@publickeys/@badges/@artifacts/@stats bypasses above ...
  handle {
    forward_auth 127.0.0.1:4180 {
      uri /oauth2/auth
      copy_headers X-Auth-Request-User X-Auth-Request-Email X-Auth-Request-Groups
      @error status 401
      handle_response @error {
        redir * /oauth2/start?rd={scheme}://{host}{uri}
      }
    }
    @api path /api/*
    reverse_proxy @api 127.0.0.1:8321   # includes /api/terminal websockets
    reverse_proxy 127.0.0.1:3000
  }
  ```

  Caddy's `reverse_proxy` speaks websockets natively and `forward_auth` runs
  on the handshake (a normal GET carrying the Authentik session cookie), so
  no extra directives are needed.
* Keep the existing `request_header -X-Auth-Request-*` stripping on every
  garnix vhost, and keep the backend bound to loopback
  (`GARNIX_SELF_HOST_MODE` already does this) so the gate cannot be walked
  around.
* The cache vhost must keep rewriting everything to `/api/cache{uri}` — that
  already makes `/api/terminal` unreachable via the cache hostname.

### Plain nginx (this repo's `backend/nixos-module.nix`)

The module now carries the required websocket location:

```nix
locations."/api/terminal/" = {
  proxyPass = "http://127.0.0.1:<port>";
  proxyWebsockets = true;   # Upgrade/Connection headers
};
```

Here the in-app gate (session auth + ownership + Origin check) is the
authentication layer, exactly as for every other authed `/api` route. If you
front nginx with an additional SSO gate, apply it to `/api/terminal` like
the rest of `/api`.

### Things that must never be done

* Do not expose `/api/terminal` on an unauthenticated vhost or add it to a
  gate-bypass list — it would still require a valid garnix session, but the
  proxy gate is a deliberate second layer.
* Do not proxy the whole backend at the cache hostname (`X-Auth-Request-*`
  forgery — see the access-control notes in the self-host docs).
* Do not place the terminal CA private key in a guest, repository, command
  argument, or Nix store path. Only its public half belongs on guests.
* No IPs, domains or keys are hardcoded for this feature: the guest address
  comes from the `servers` table at connect time, the CA path comes from
  `GARNIX_TERMINAL_CA_KEY`, and a new ephemeral session identity is minted for
  each connection.
