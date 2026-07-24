# garnix Hosting Security Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the self-hosted garnix CI "hosting" feature (deployed guest microVMs, the web terminal, the public gateway, the auth gate, and secret handling) so a single-tenant instance (owner + trusted friends) can run production workloads with a compromised-guest / blast-radius-reduction posture.

**Architecture:** Changes land in two repos. (1) The fork `garnix-ci-selfhosted` (`~/Development/garnix-ci`, branch `main`): the Haskell backend (`backend/src/Garnix/**`), its NixOS module (`backend/nixos-module.nix`), and the microVM provisioner (`provisioner/{nixos-module.nix,guest-profile.nix,provisionerd.py}`). (2) The dotfiles repo (`~/dotfiles`): the erdtree aspect `modules/hosts/erdtree/garnix.nix` and agenix recipients in `~/dotfiles-secrets/secrets.nix`. The backend and provisioner exchange several new config knobs (a proxy-provenance marker secret, a dedicated web-terminal signing CA, a guest-subnet gate); the cross-component contracts are pinned in the table below so names match exactly across files.

**Tech Stack:** Haskell (Servant, `postgresql-typed`, `servant-auth-server`, hspec), NixOS modules (agenix, microvm.nix, Caddy, oauth2-proxy, Authentik), Python 3 (the provisioner daemon), iptables/nftables, `bridge`/`ip` from iproute2.

---

## Global Constraints

- **Fork repo & branch:** `~/Development/garnix-ci`, remote `origin = git@github.com:joegoldin/garnix-ci-selfhosted.git`, branch **`main`** (tracks `origin/main`). The dotfiles input is `garnix-ci = { url = "github:joegoldin/garnix-ci-selfhosted"; }` (default branch `main`). The older skill note "branch `self-hosting`" is **stale** — commit fork changes to `main`.
- **New files must be `git add`ed** before any nix build: a git-repo flake excludes untracked files from its source (`can't find source for …`). Modified tracked files are picked up from the working tree without staging.
- **Backend compile gate (authoritative):** `nix build .#backend_garnixHaskellPackage --no-link --print-out-paths` run from `~/Development/garnix-ci`. **Check the exit status directly — do NOT pipe through `tail`** (it masks nix's non-zero exit). On failure, read the real error with `nix log /nix/store/<hash>-garnix-0.1.0.0.drv`. Bare `cabal build` fails: `postgresql-typed`'s `pgSQL` quasi-quoter connects to Postgres at compile time; the nix sandbox spins up a temporary Postgres.
- **Provisioner Python gate:** `nix build .#checks.x86_64-linux.provisionerdPortTests` (added in this plan), or `python3 -m unittest test_provisionerd_ports -v` from `provisioner/` with the `PROVISIONER_*` env pinned.
- **Nix aspect gate:** from `~/dotfiles`, `set -x NIX_CONFIG "access-tokens = github.com=$(gh auth token)"` then `nix build .#nixosConfigurations.erdtree.config.system.build.toplevel --dry-run` (or option-level `nix eval` probes). `nix-instantiate --parse <file>` for quick syntax checks of provisioner `.nix`.
- **Deploy:** `just build-to-erdtree` (builds on erdtree; it's beefy) or `just build-to-erdtree --local` (build locally, copy closure). The recipe injects `NIX_CONFIG="access-tokens = github.com=$(gh auth token)"` so private flake inputs fetch. **Deploying restarts `garnixServer`, killing in-flight builds** (they orphan as "Pending") — deploy between builds.
- **Fork→dotfiles round-trip:** after committing+pushing fork changes, in `~/dotfiles` run `set -x NIX_CONFIG "access-tokens = github.com=$(gh auth token)"; nix flake update garnix-ci`, then deploy.
- **Secrets (agenix):** managed from `~/dotfiles-secrets`. **Never `EDITOR=cp agenix -e`** under a non-TTY (corrupts the file). Pipe via **stdin**: `agenix -e x.age < file`. **Strip trailing newlines** on tokens/secrets consumed by header comparisons. Recipients for all new secrets: `users ++ [ erdtree ]`. After editing `secrets.nix` + creating `.age` files, commit+push `dotfiles-secrets`, then `nix flake update dotfiles-secrets` in `~/dotfiles`.
- **Deploy ordering (critical, fail-closed changes):**
  1. Create the 3 new agenix secrets **first** and update the `dotfiles-secrets` input, so the secret files exist on erdtree before the backend/Caddy that require them.
  2. M3 (proxy marker) and H3 (terminal CA) are **fail-closed**: the Caddy header-inject + the backend's marker check land in the **same** `just build-to-erdtree` deploy, and the terminal-CA secret must be present. New browser logins break if the backend requires the marker before Caddy injects it — one atomic deploy avoids this.
  3. After deploy: run the M4 `repo_config` DB cleanup, then **recycle pool guests / recreate existing guests** (they predate tap-isolation, the guest firewall, and the terminal-CA trust — see Task 19).
- **Single-tenant threat model:** owner + a few trusted friends. Fixes target compromised-guest containment, blast-radius reduction, and correctness — **not** defense against a deliberately nefarious tenant. Multi-tenant-abuse findings (C2 `/nix/store` share, C3 `servers[].domains` ownership, H4 quotas, H6 LE-cert exhaustion) are intentionally **out of scope**.

---

## Cross-Component Contract (names MUST match verbatim across files)

| Concept | Exact value | Producer → Consumer |
|---|---|---|
| Proxy-provenance header | `X-Garnix-Proxy-Auth` | Caddy injects on `@api` only; backend validates; both vhosts strip it inbound |
| Proxy secret file | `/run/secrets/garnix_proxy_shared_secret` (owner `garnix`, group `garnix-proxy-auth`, `0440`) | agenix → caddy (per-request `{file.*}` read) + backend (startup read, `T.strip`, `==`) |
| Proxy secret env | `GARNIX_PROXY_SHARED_SECRET_FILE` (path; module-set) · `GARNIX_PROXY_SHARED_SECRET` (literal; dev only, never module-set) | backend `nixos-module.nix` → backend `Garnix.hs` |
| Proxy Env field | `proxySharedSecret :: Maybe Text` | `Monad.hs` / `Garnix.hs` / `TestHelpers/Monad.hs` / `Auth.hs` |
| Terminal CA private key | `/run/secrets/garnix_terminal_ca` (owner `garnix`, `0400`) | agenix → backend (sign) + provisioner root ExecStartPre (derive pub) |
| Terminal CA public key | `/run/secrets/garnix_terminal_ca_pub` (`0440`) and derived `/var/lib/garnix-provisioner/terminal-ca.pub` (`0644`) | provisioner → guest injection |
| Terminal CA backend env | `GARNIX_TERMINAL_CA_KEY` (path; default `/run/secrets/garnix_terminal_ca`) | backend `nixos-module.nix` → `Garnix.hs` → Env `sshTerminalCaKey :: FilePath` |
| Terminal source-address env | `GARNIX_TERMINAL_SOURCE_ADDRESS` = `10.111.0.1/32` | backend `nixos-module.nix` → `Garnix.hs` → Env `sshTerminalSourceAddress :: Maybe Text` |
| Provisioner host option | `garnix.local-provisioner.terminalCaPrivateKeyPath` (str, default `/run/secrets/garnix_terminal_ca`) | provisioner `nixos-module.nix`; aspect sets it |
| Provisioner daemon env | `PROVISIONER_TERMINAL_CA_PUBKEY_FILE=/var/lib/garnix-provisioner/terminal-ca.pub` | provisioner `nixos-module.nix` → `provisionerd.py` |
| Guest CA option | `garnix.guest.terminalCaPublicKey` (str, **default `config.garnix.guest.sshPublicKey`**) → `TrustedUserCAKeys` | `provisionerd.py` injects; `guest-profile.nix` consumes |
| Guest-subnet gate env | `GARNIX_GUEST_SUBNET_PREFIX` = `10.111.0.` | backend `nixos-module.nix`(optional) / default → `Garnix.hs` → Env `guestSubnetPrefix :: Text` |
| Egress blocklist option | `garnix.local-provisioner.guestEgressBlocklist` (list of CIDR) | provisioner `nixos-module.nix`; aspect appends `147.224.12.5/32` |
| Guest CPU model option | `garnix.local-provisioner.guestCpuModel` (nullOr str, default null) | provisioner `nixos-module.nix` → env `PROVISIONER_GUEST_CPU` → `provisionerd.py` |
| Port-range end env | `PROVISIONER_PORT_RANGE_END` = `41999` | provisioner `nixos-module.nix` → `provisionerd.py` |

**Fail-closed reconciliation (decided):** the backend signs terminal certs with `GARNIX_TERMINAL_CA_KEY` and **404s the terminal if that file is absent — NO fallback to the hosting key** (`Terminal.hs`). The provisioner/guest side *does* fall back to the hosting pubkey for evaluability only (so guests stay buildable if the secret is missing) — these are not in conflict: guest-evaluability fallback ≠ backend-signing fallback. In normal operation the secret exists, so the backend signs with the dedicated CA and guests trust the dedicated CA.

---

## Security Report (embedded)

This plan implements the findings below. Severity reflects the multi-tenant analysis; under the single-tenant model in scope here, the value is compromised-guest containment and correctness. **In scope:** C1, H1, H2, H3, H5, M1, M2, M3, M4, M5, M6, M7, M8, and low/info items. **Out of scope (trusted tenants):** C2, C3, H4, H6.

- **C1 — Tenant↔tenant isolation rests on an unpinned sysctl.** The only guest↔guest barrier is `iptables -I FORWARD -i garnixbr0 -o garnixbr0 -j DROP`, effective only when `bridge-nf-call-iptables=1`. Live checks observed that sysctl flipping `0`→`1` within one session; nothing pins it and Docker shares it. Guests are one flat `/24` with guest firewalls disabled and no TAP `isolated` flag. → bridge **port isolation** on each TAP (L2, sysctl-independent) + guest firewall + pin the sysctl.
- **H1 — Web-terminal authz is org-membership, not repo-collaborator.** A low-priv org member can open an interactive shell (→ root via `sudo`) on a guest built from a repo they can't access. → require `hasAccessToRepo` before minting.
- **H2 — Terminal cert is an unscoped cross-tenant key** (no host binding / source-address, arbitrary principal incl. `root`, shared CA, 70m). → restrict principal to declared users (reject `root`), add per-guest principal + `source-address`, unique key-id, `+61m` validity.
- **H3 — One key is deploy-identity + root `authorized_key` + terminal CA.** → a dedicated terminal-signing CA split from the deploy/root hosting key.
- **H5 — Unrestricted guest egress to LAN / internal hosts** (remote builder, router, RFC1918). → egress ACL dropping bridge→private/LAN/named-internal before NAT.
- **M1 — repo-secrets decryption key at rest inside the guest** (`/var/garnix/keys/repo-key`, an `AGE-SECRET-KEY`). It's a *runtime* key (re-read on every boot/service restart by `garnix-authentik-secrets`), so it can't be shredded → mount `/var/garnix/keys` as **tmpfs** (RAM-only, never on the persistent `root.img`), and re-copy it on redeploy (tmpfs is lost on power-cycle). C1 additionally stops a neighbor reading it live.
- **M2 — fluent-bit is in `garnix` group** and can read every `0440` backend secret. → dedicated `garnix-opensearch` group.
- **M3 — header trust is presence-not-provenance.** Currently not reachable from CI sandboxes (`--unshare-net`, `sandbox = true`), but any future host-local process on `:8321` = admin. → require a Caddy-injected marker header.
- **M4 — self-host auto-allows public-repo → private-flake-input with no collaborator check.** → keep the collaborator gate in self-host mode; preserve private-cache routing.
- **M5 — `on-demand-check` is uncached** (3 DB queries/SNI). → memoize the allowed-domain set ~10s.
- **M6 — uplink opens 22000–41999, overlapping the kernel ephemeral range 32768+.** → raise `ip_local_port_range` above the exposed range.
- **M7 — DNAT host-port = `id mod N`** → cross-tenant collision + stale rules. → real free-list + flush-before-add.
- **M8 — L2 spoofing (ARP/DHCP/RA)** on the shared bridge. → port isolation + `accept_ra=0` + IPv4-only guests.
- **Low/info:** remote-builder SSH key `0440`→`0400`; session JWT has **no expiry at all** → 30m TTL; unauthenticated `/api/hosts/stats` spoofable → guest-subnet source gate; deployer keys always from `github.com` → forge-aware; `-cpu host` passthrough → optional fixed model; no L7 rate-limiting → optional Caddy plugin; confirm Authentik enrollment closed.

---

## File Structure

**Fork (`~/Development/garnix-ci`):**
- `backend/src/Garnix/Monad.hs` — Env record: 4 new fields.
- `backend/src/Garnix.hs` — Env construction: 4 new env-var reads.
- `backend/test/spec/Garnix/TestHelpers/Monad.hs` — test Env: 4 new defaults.
- `backend/src/Garnix/API/Terminal.hs` — H1/H2/H3 + cert TTL/key-id.
- `backend/src/Garnix/FlakeInputAuthorization.hs` — M4.
- `backend/src/Garnix/API/Hosts.hs` — M5 + stats source gate.
- `backend/src/Garnix/API/Auth.hs` — M3 marker + JWT TTL.
- `backend/src/Garnix/Hosting/Deploy.hs` — forge-aware deployer keys; re-copy repo key on redeploy (M1).
- `backend/nixos-module.nix` — options `proxySharedSecretFile`, `terminalCaKeyPath`, `terminalSourceAddress` + env wiring.
- `backend/test/spec/SpecHook.hs` — clear the new on-demand cache between specs.
- `backend/test/spec/Garnix/API/{TerminalSpec,HostsSpec,AuthSpec}.hs` — new unit tests.
- `provisioner/nixos-module.nix` — tap isolation hook, sysctl block, egress ACL, terminal-CA derivation, options, doc fixes.
- `provisioner/provisionerd.py` — tap spec, terminal-CA read/emit, CPU line, DNAT free-list.
- `provisioner/guest-profile.nix` — firewall, IPv4-only/RA, terminalCaPublicKey option + TrustedUserCAKeys swap, `/var/garnix/keys` tmpfs (M1).
- `provisioner/test_provisionerd_ports.py` (new) + `provisioner/default.nix` — port-allocator tests.

**Dotfiles (`~/dotfiles`, `~/dotfiles-secrets`):**
- `dotfiles-secrets/secrets.nix` — 3 new agenix recipients.
- `modules/hosts/erdtree/garnix.nix` — secret installs + per-secret groups + key modes, fluent-bit group, Caddy marker inject + `@stats` gate, `services.garnixServer` + `local-provisioner` new settings, optional rate-limit.

---

## Phase Overview

- **Phase 1 — Backend (Haskell + backend module):** Tasks 1–9. One compile gate (`backend_garnixHaskellPackage`) covers Haskell; the backend `nixos-module.nix` is eval-checked with the aspect.
- **Phase 2 — Provisioner (Nix + Python):** Tasks 10–16.
- **Phase 3 — Dotfiles aspect + secrets:** Tasks 17–21.
- **Phase 4 — Deploy, migrate, verify:** Tasks 22–25.

Within Phase 1, **Task 1 (Env plumbing) must land first** — Tasks 2/4/5 consume the new Env fields.

---

# Phase 1 — Backend

## Task 1: Backend Env plumbing (4 new fields)

Adds the four new `Env` fields consumed by later backend tasks, their env-var reads, and test defaults. Compiles green on its own (the fields are constructed everywhere `Env` is built; unused selectors don't error).

**Files:**
- Modify: `backend/src/Garnix/Monad.hs` (the `Env` record, ~line 105–148)
- Modify: `backend/src/Garnix.hs` (`withEnv`, env-var reads ~line 254–277 and the `Env {…}` construction ~line 428–448)
- Modify: `backend/test/spec/Garnix/TestHelpers/Monad.hs` (test `Env` construction ~line 253–327)

**Interfaces:**
- Produces (used by Tasks 2/4/5): `sshTerminalCaKey :: FilePath`, `sshTerminalSourceAddress :: Maybe Text`, `proxySharedSecret :: Maybe Text`, `guestSubnetPrefix :: Text` on `Env`, addressable via generic-lens `view #field`.

- [ ] **Step 1: Add the four fields to the `Env` record.** In `backend/src/Garnix/Monad.hs`, immediately after the existing `sshUserHostingKeys :: [FilePath],` line (~line 116), insert:

```haskell
    -- | Private key of the dedicated web-terminal certificate authority
    -- (GARNIX_TERMINAL_CA_KEY, default /run/secrets/garnix_terminal_ca).
    -- Guests trust the matching public key via TrustedUserCAKeys; this key
    -- signs only short-lived per-session terminal certs and is never a
    -- deploy identity.
    sshTerminalCaKey :: FilePath,
    -- | CIDR terminal certs are valid from (@-O source-address@;
    -- GARNIX_TERMINAL_SOURCE_ADDRESS, e.g. "10.111.0.1/32" — the host's
    -- address on the guest bridge). 'Nothing' omits the restriction.
    sshTerminalSourceAddress :: Maybe Text,
    -- | Shared secret proving a request traversed the authenticating gateway;
    -- the gateway injects it as X-Garnix-Proxy-Auth. Nothing outside self-host
    -- mode; in self-host mode an unconfigured secret fails closed.
    proxySharedSecret :: Maybe Text,
    -- | Dotted-decimal prefix of the guest bridge subnet (default the local
    -- provisioner's 10.111.0.1/24 bridge); /api/hosts/stats only accepts
    -- samples from it in self-host mode. GARNIX_GUEST_SUBNET_PREFIX.
    guestSubnetPrefix :: Text,
```

- [ ] **Step 2: Read the env vars in `withEnv`.** In `backend/src/Garnix.hs`, near the existing `sshKeys` / `GARNIX_ACTION_RUNNER_SSH_KEY` parsing (~line 254) and the `selfHostMode'` line (~line 276), add (`makeAbsolute`, `lookupEnv`, `BSC` are already in scope):

```haskell
    sshTerminalCaKey' <-
      lookupEnv "GARNIX_TERMINAL_CA_KEY"
        >>= maybe (pure "/run/secrets/garnix_terminal_ca") makeAbsolute
    sshTerminalSourceAddress' <- fmap cs <$> lookupEnv "GARNIX_TERMINAL_SOURCE_ADDRESS"
    proxySharedSecret' <-
      if selfHostMode'
        then
          lookupEnv "GARNIX_PROXY_SHARED_SECRET_FILE" >>= \case
            Just path -> Just . T.strip . cs <$> BSC.readFile path
            Nothing -> fmap (T.strip . cs) <$> lookupEnv "GARNIX_PROXY_SHARED_SECRET"
        else pure Nothing
    guestSubnetPrefix' <- maybe "10.111.0." cs <$> lookupEnv "GARNIX_GUEST_SUBNET_PREFIX"
```

- [ ] **Step 3: Thread them into the `Env {…}` record.** In the same file, in the `Env` construction (after `sshUserHostingKeys = sshKeys,`, ~line 428, and near `selfHostMode = selfHostMode',`), add:

```haskell
      sshTerminalCaKey = sshTerminalCaKey',
      sshTerminalSourceAddress = sshTerminalSourceAddress',
      proxySharedSecret = proxySharedSecret',
      guestSubnetPrefix = guestSubnetPrefix',
```

- [ ] **Step 4: Add test-Env defaults.** In `backend/test/spec/Garnix/TestHelpers/Monad.hs`, in the `Env {…}` construction (~line 253–327; `sshKey` is the already-canonicalized `"ssh-key-for-tests"`), add:

```haskell
      sshTerminalCaKey = sshKey,
      sshTerminalSourceAddress = Nothing,
      proxySharedSecret = Nothing,
      guestSubnetPrefix = "10.111.0.",
```

- [ ] **Step 5: Compile gate.**

Run: `nix build .#backend_garnixHaskellPackage --no-link --print-out-paths`
Expected: exit 0 (a store path printed). On failure: `nix log /nix/store/<hash>-garnix-0.1.0.0.drv`.

- [ ] **Step 6: Commit.**

```bash
git -C ~/Development/garnix-ci add backend/src/Garnix/Monad.hs backend/src/Garnix.hs backend/test/spec/Garnix/TestHelpers/Monad.hs
git -C ~/Development/garnix-ci commit -m "backend(env): add terminal-CA, terminal source-address, proxy-secret, guest-subnet fields"
```

---

## Task 2: Web terminal — H1 (repo-access gate) + H2 (cert scoping) + H3 (dedicated CA)

All three edit `connectTerminal`, so they land as one consolidated function plus the `prepareCertSsh`/`signingArgs`/`requireDeclaredLoginUser` changes. Consumes `sshTerminalCaKey` and `sshTerminalSourceAddress` from Task 1.

**Files:**
- Modify: `backend/src/Garnix/API/Terminal.hs`
- Test: `backend/test/spec/Garnix/API/TerminalSpec.hs`

**Interfaces:**
- Consumes: Env `sshTerminalCaKey`, `sshTerminalSourceAddress` (Task 1); `hasAccessToRepo` (`Garnix.Access`), `DB.getBuild`, `RunningServer` fields `_runningServerRepoOwner/_runningServerRepoName/_runningServerConfigurationBuildId/_runningServerSshUsers` (`Garnix.Hosting.Helpers`).
- Produces (for tests): exports `TerminalTarget (..)`, `signingArgs`.
- Contract to provisioner: guests must trust the **terminal CA public key** as `TrustedUserCAKeys` (Task 15); the login-user principal keeps sshd's default match working, so no `AuthorizedPrincipalsFile` is required (H2 guest-side deferred — Task 15 Item 5).

- [ ] **Step 1: Write the failing pure test for `signingArgs`.** In `backend/test/spec/Garnix/API/TerminalSpec.hs` add `import Garnix.API.Terminal (TerminalTarget (..), signingArgs)` and, outside any `inM` block:

```haskell
  describe "signingArgs" $ do
    it "mints a tightly-scoped certificate" $ do
      let target =
            TerminalTarget
              { ttBaseArgs = [],
                ttGuestHost = "10.111.0.5",
                ttLoginUser = "alice",
                ttCaKeyFile = "/run/secrets/garnix_terminal_ca",
                ttServerIdText = "vBV73Z9e",
                ttSourceAddress = Just "10.111.0.1/32"
              }
      signingArgs target "123e4567-e89b-12d3-a456-426614174000" "/tmp/id"
        `shouldBe` [ "-s",
                     "/run/secrets/garnix_terminal_ca",
                     "-I",
                     "garnix-web-terminal-vBV73Z9e-123e4567-e89b-12d3-a456-426614174000",
                     "-n",
                     "alice,server-vBV73Z9e",
                     "-V",
                     "+61m",
                     "-O",
                     "clear",
                     "-O",
                     "permit-pty",
                     "-O",
                     "source-address=10.111.0.1/32",
                     "/tmp/id.pub"
                   ]
```

- [ ] **Step 2: Update the module header — exports + imports.** Replace the export list (`Terminal.hs:35-39`):

```haskell
module Garnix.API.Terminal
  ( TerminalAPI (..),
    terminalAPI,

    -- * Exported for the spec
    TerminalTarget (..),
    signingArgs,
  )
where
```

Then add these five imports to the import list (`Terminal.hs:41-69`), preserving alphabetical order:

```haskell
import Data.UUID qualified
import Data.UUID.V4 qualified
import Garnix.Access (hasAccessToRepo)
import Garnix.DB qualified as DB
import System.Directory (doesFileExist)
```

- [ ] **Step 3: Replace `connectTerminal` (the whole function, `Terminal.hs:103-146`)** with the consolidated version:

```haskell
connectTerminal :: AuthResult AuthJwtPayload -> ServerId -> Maybe Text -> M Wai.Application
connectTerminal (Authenticated (WebSession user ghToken)) serverId requestedUser = do
  loginUser <- validateLoginUser requestedUser
  servers <-
    getRunningAndRecentServersForOwners
      . (GhRepoOwner (user ^. githubLogin) :)
      . map organizationName
      =<< getInstalledOrgs ghToken
  -- Ownership gate: same membership check as getServerStats/deleteHost.
  server <- case find ((== serverId) . _runningServerId) servers of
    Just server -> pure server
    Nothing -> do
      log Notice "terminal: websocket rejected (server not owned or unknown)"
      throw NotFound
  -- [H1] Repo-access gate: org membership alone is too coarse for a shell.
  -- The caller must also have access to the repo this server was deployed
  -- from (public repo, admin, or collaborator — the same 'hasAccessToRepo'
  -- the build/commit/artifact endpoints use). Publicity comes from the
  -- server's configuration build row, the same DB snapshot
  -- 'getBuildWithAccess' trusts, so connecting stays forge-round-trip-free.
  build <- DB.getBuild (_runningServerConfigurationBuildId server)
  hasAccess <-
    hasAccessToRepo
      (Just user)
      (build ^. repoIsPublic)
      (_runningServerRepoOwner server)
      (_runningServerRepoName server)
  unless hasAccess $ do
    log Notice "terminal: websocket rejected (no access to the server's repo)"
    throw NotFound
  -- [H2a] Login-user gate, now that the server row is known: only users the
  -- guest actually declares (plus the deploy user), never root.
  requireDeclaredLoginUser server loginUser
  unless (_runningServerStatus server == Online) $ do
    log Notice "terminal: websocket rejected (server not online)"
    throw NotFound
  guestAddr <- case _runningServerIpv4 server of
    Just addr | isPlausibleGuestAddr addr -> pure addr
    _ -> do
      log Notice "terminal: websocket rejected (server has no usable guest address)"
      throw NotFound
  -- Reuse the deploy path's ssh mechanism verbatim: BatchMode, internal-guest
  -- host-key handling, connect timeout, port split. We ssh straight in as the
  -- chosen login user, authenticating with a short-lived per-session
  -- certificate minted per connection (the guest trusts the terminal CA), so
  -- a declared login user like @joe@ is reachable directly without any
  -- standing key for them.
  (guestHost, sshArgs) <- ServerPool.sshArgsFor (GuestAddress guestAddr)
  -- [H3] The dedicated terminal certificate authority (never the
  -- hosting/deploy key): guests trust its public half via TrustedUserCAKeys,
  -- so the deploy/root identity and the terminal-signing identity stay
  -- separable. Absent key file fails closed, before any upgrade.
  caKeyFile <- do
    path <- view #sshTerminalCaKey
    exists <- liftIO $ doesFileExist path
    unless exists $ do
      log Notice "terminal: websocket rejected (terminal CA key not present)"
      throw NotFound
    pure (cs path)
  sourceAddress <- view #sshTerminalSourceAddress
  env <- ask
  pure
    $ terminalApp env (getGhLogin (user ^. githubLogin)) serverId
    $ TerminalTarget
      { ttBaseArgs = sshArgs <> sshHardeningArgs,
        ttGuestHost = guestHost,
        ttLoginUser = loginUser,
        ttCaKeyFile = caKeyFile,
        ttServerIdText = getHashId (getServerId serverId),
        ttSourceAddress = sourceAddress
      }
connectTerminal _ _ _ = do
  log Notice "terminal: unauthenticated websocket rejected"
  throw Unauthorized
```

- [ ] **Step 4: Add the `requireDeclaredLoginUser` gate + refresh `validateLoginUser` comment.** Replace `Terminal.hs:148-175` (the `validateLoginUser` doc-block through `isValidLoginUser`) with:

```haskell
-- | The guest login user. Defaults to @garnix@ (the deploy user). A
-- client-supplied override is the single client-influenced token of the ssh
-- argv, so it is gated by a strict allowlist pattern
-- (@^[a-z_][a-z0-9_-]{0,31}$@): it can never start with @-@ (no option
-- injection), never contain whitespace, @\@@, or any shell/ssh
-- metacharacter, and is length-bounded. Anything else is a 400 before any
-- process is spawned. This is only the syntactic gate; once the server row
-- is known, 'requireDeclaredLoginUser' additionally requires the user to be
-- one the guest declared (and never root).
validateLoginUser :: Maybe Text -> M Text
validateLoginUser = \case
  Nothing -> pure defaultLoginUser
  Just requested
    | isValidLoginUser requested -> pure requested
    | otherwise -> do
        log Notice "terminal: websocket rejected (invalid login user)"
        throw $ BadRequest "invalid terminal login user"

defaultLoginUser :: Text
defaultLoginUser = "garnix"

-- | Second gate on the login user, once the server row is known: a session
-- certificate is only minted for login users the guest actually declared at
-- deploy time (servers.ssh_users, captured on the guest via getent — see
-- '_runningServerSshUsers') plus the deploy user @garnix@. @root@ never gets
-- one, even if a guest were to declare it: the web terminal is for
-- interactive logins as declared users, not a root channel.
requireDeclaredLoginUser :: RunningServer -> Text -> M ()
requireDeclaredLoginUser server loginUser
  | loginUser == "root" = do
      log Notice "terminal: websocket rejected (root login refused)"
      throw $ BadRequest "terminal login as root is not allowed"
  | loginUser == defaultLoginUser = pure ()
  | loginUser `elem` fromMaybe [] (_runningServerSshUsers server) = pure ()
  | otherwise = do
      log Notice "terminal: websocket rejected (login user not declared by this server)"
      throw $ BadRequest "login user not declared by this server"

isValidLoginUser :: Text -> Bool
isValidLoginUser user = case T.uncons user of
  Nothing -> False
  Just (first', rest) ->
    T.length user <= 32
      && (isAsciiLower first' || first' == '_')
      && T.all (\c -> isAsciiLower c || isDigit c || c == '_' || c == '-') rest
```

- [ ] **Step 5: Replace `TerminalTarget` + `prepareCertSsh` and add `signingArgs`.** Replace `Terminal.hs:218-228` (the `TerminalTarget` record + its doc) and `Terminal.hs:323-359` (the `prepareCertSsh` doc + body) with:

```haskell
-- | Everything the per-session handler needs to build the ssh command once it
-- has minted the session certificate: the base ssh args (hosting-key @-i@
-- flags + BatchMode/host-key/port options + the terminal hardening flags, with
-- no destination yet), the guest host, the chosen login user, and the terminal
-- CA key file the per-session cert is signed with.
data TerminalTarget = TerminalTarget
  { ttBaseArgs :: [Text],
    ttGuestHost :: Text,
    ttLoginUser :: Text,
    ttCaKeyFile :: Text,
    -- | The server's public hash id (the one in its URLs). Used for the
    -- per-guest cert principal @server-\<id\>@ — so a guest can pin terminal
    -- certs to itself via @AuthorizedPrincipalsFile@ — and for the unique
    -- per-session key id.
    ttServerIdText :: Text,
    -- | When set, baked into the cert as @-O source-address=...@: the cert
    -- then only authenticates from this CIDR (the backend's own address on
    -- the guest bridge; GARNIX_TERMINAL_SOURCE_ADDRESS).
    ttSourceAddress :: Maybe Text
  }

-- | Mint an ephemeral, per-session SSH user certificate for the target login
-- user in @dir@ and return the ssh argv that authenticates with it. The guest
-- trusts the dedicated terminal CA (@TrustedUserCAKeys@, see
-- @provisioner/guest-profile.nix@), so a short-lived cert signed by it logs us
-- in directly as any declared user without any standing key for them. The
-- throwaway keypair + cert live only in @dir@ (removed when the session ends),
-- the guest is never mutated, and the cert's scope is pinned down by
-- 'signingArgs'.
prepareCertSsh :: FilePath -> TerminalTarget -> IO [String]
prepareCertSsh dir target = do
  let keyPath = dir </> "id"
      certPath = dir </> "id-cert.pub"
  sessionUuid <- Data.UUID.toText <$> Data.UUID.V4.nextRandom
  runKeygen ["-q", "-t", "ed25519", "-N", "", "-C", "garnix-terminal", "-f", keyPath]
  runKeygen (signingArgs target sessionUuid keyPath)
  pure
    $ map cs (ttBaseArgs target)
      <> [ "-i",
           keyPath,
           "-o",
           "CertificateFile=" <> certPath,
           cs (ttLoginUser target) <> "@" <> cs (ttGuestHost target)
         ]

-- | The @ssh-keygen -s@ argv that signs a session certificate (pure, so the
-- spec can pin down exactly what a cert grants):
--
--   * principals: the login user plus @server-\<serverId\>@ — the login-user
--     principal is what sshd matches by default; the per-server principal
--     lets a guest restrict certs to itself via @AuthorizedPrincipalsFile@;
--   * key id: unique per session (server id + session UUID), so guest auth
--     logs attribute each login to exactly one websocket session;
--   * validity: +61m, just over the 60m 'maxSessionDuration' cap (sshd only
--     checks validity once, at authentication);
--   * options: cleared, then @permit-pty@ only — no forwardings — plus
--     @source-address@ pinning the cert to the backend's own guest-bridge
--     address when configured.
signingArgs :: TerminalTarget -> Text -> FilePath -> [String]
signingArgs target sessionUuid keyPath =
  [ "-s",
    cs (ttCaKeyFile target),
    "-I",
    cs ("garnix-web-terminal-" <> ttServerIdText target <> "-" <> sessionUuid),
    "-n",
    cs (ttLoginUser target <> ",server-" <> ttServerIdText target),
    "-V",
    "+61m",
    "-O",
    "clear",
    "-O",
    "permit-pty"
  ]
    <> maybe [] (\addr -> ["-O", cs ("source-address=" <> addr)]) (ttSourceAddress target)
    <> [keyPath <> ".pub"]
```

- [ ] **Step 6: Update the module-header security bullets.** In `Terminal.hs:10-27`, revise the posture comment to mention the added `hasAccessToRepo` gate, the declared-login-user/never-root gate, and the dedicated terminal CA (`sshTerminalCaKey`) — the old text claiming ownership is the only gate and that the guest trusts the hosting key for every user is now inaccurate.

- [ ] **Step 7: Add the HTTP-level login-user tests.** In `TerminalSpec.hs`, generalize the local `createServer` to take publicity (so H1's private-repo path is testable) and add the tests. Replace the hardcoded `(RepoIsPublic True)` at `TerminalSpec.hs:138` by introducing:

```haskell
createServerWithPublicity :: RepoPublicity -> GhRepoOwner -> GhRepoName -> Branch -> PackageName -> User -> (ServerInfo -> ServerInfo) -> M ServerInfo
createServerWithPublicity publicity repoOwner repoName branch packageName user updateServerInfo = do
  let commitInfo =
        CommitInfo
          (user ^. githubLogin)
          publicity
          (RepoInfo ForgeGithub Nothing undefined repoOwner repoName)
          (Just branch)
          Nothing
          (CommitHash "baz")
  build <-
    DB.newBuildDB
      commitInfo
      (PackageInfo TypePackage (IsSystem X8664Linux) packageName)
      "garnix-server-test"
      False
  DB.reportBuildResultDB build
  now <- liftIO getCurrentTime
  addTestServer $ updateServerInfo . \server ->
    server
      & configurationBuildId .~ (build ^. id)
      & readyAt ?~ now

createPrivateServer :: User -> (ServerInfo -> ServerInfo) -> M ServerInfo
createPrivateServer user =
  createServerWithPublicity
    (RepoIsPublic False)
    (GhRepoOwner $ user ^. githubLogin)
    (GhRepoName "repo")
    (Branch "branch")
    (PackageName "package")
    user
```

and redefine the existing `createServer owner name … = createServerWithPublicity (RepoIsPublic True) owner name …` so its two call sites (TerminalSpec.hs:40, 126) are unchanged. Then add:

```haskell
      it "responds with 404 for an owned server on a private repo without collaborator access" $ withServer $ \testServer -> do
        user <- testServer.login
        server <- createPrivateServer user (ipv4Addr .~ "10.0.0.1")
        result <- testServer.get (terminalPath server)
        result `shouldHaveStatusCode` 404

      it "refuses a root terminal login" $ withServer $ \testServer -> do
        user <- testServer.login
        server <- createSimpleServer user (ipv4Addr .~ "10.0.0.1")
        result <- testServer.get (terminalPath server <> "?user=root")
        result `shouldHaveStatusCode` 400

      it "refuses a login user the guest did not declare" $ withServer $ \testServer -> do
        user <- testServer.login
        server <- createSimpleServer user (ipv4Addr .~ "10.0.0.1")
        result <- testServer.get (terminalPath server <> "?user=alice")
        result `shouldHaveStatusCode` 400

      it "accepts a login user the guest declared" $ withServer $ \testServer -> do
        user <- testServer.login
        server <- createSimpleServer user (ipv4Addr .~ "10.0.0.1")
        DB.setServerSshUsers (server ^. id) ["alice"]
        result <- testServer.get (terminalPath server <> "?user=alice")
        result `shouldHaveStatusCode` 426
```

(`createSimpleServer` = an owned public server built via `createServer`; use whichever public-server helper the spec already provides. `426` is the websocket-upgrade-required status returned once auth passes.)

- [ ] **Step 8: Compile gate + run the terminal spec.**

Run: `nix build .#backend_garnixHaskellPackage --no-link --print-out-paths`
Expected: exit 0. End-to-end cert acceptance by a real guest sshd (CA trust, source-address, principals) is integration-only (Task 20).

- [ ] **Step 9: Commit.**

```bash
git -C ~/Development/garnix-ci add backend/src/Garnix/API/Terminal.hs backend/test/spec/Garnix/API/TerminalSpec.hs
git -C ~/Development/garnix-ci commit -m "backend(terminal): repo-access gate (H1), scoped certs + no-root (H2), dedicated terminal CA (H3)"
```

---

## Task 3: M4 — re-enable the private-input collaborator gate in self-host mode

**Files:**
- Modify: `backend/src/Garnix/FlakeInputAuthorization.hs:103-126`

**Interfaces:**
- Consumes: `DB.upsertRepoConfig :: GhRepoOwner -> GhRepoName -> Bool -> Bool -> M ()` (args: `skipInputChecks` then `privateCache`).
- Produces: a one-time DB cleanup requirement (Task 22) — the old code force-persisted `skip_private_inputs_check_for_collaborators = true` for every self-host public repo.

- [ ] **Step 1: Replace the public-repo branch (`FlakeInputAuthorization.hs:103-126`).** Two logic changes (drop `selfHost ||`; upsert third arg `True` → the real flag) plus the comment:

```haskell
  case privateInputs of
    [] -> pure $ NixConfig mempty
    _
      | isRepoPublic selfRepoPublicity -> do
          -- A public repo may only depend on private flake inputs with the
          -- explicit per-repo opt-in (skip_private_inputs_check_for_collaborators,
          -- settable via the admin API) — the same policy as upstream, including
          -- in self-host mode. When the opt-in allows it, self-host additionally
          -- persists that this repo's cache is private (an idempotent upsert, so
          -- it only writes the first time), keeping the resulting closures off
          -- the unauthenticated public cache; S3Cache reads private_cache to
          -- route the upload to the authenticated bucket.
          selfHost <- view #selfHostMode
          let skipPrivateInputChecks = repoConfig ^. skipPrivateInputsCheckForCollaborators
          unless skipPrivateInputChecks $ do
            throw
              $ OtherError
              $ "Public repository has private dependencies, which is not allowed. Private dependencies: "
              <> T.unwords (fmap showPretty privateInputs)
          when (selfHost && not (repoConfig ^. privateCache))
            $ DB.upsertRepoConfig (repoInfo' ^. ghRepoOwner) (repoInfo' ^. ghRepoName) (repoConfig ^. skipPrivateInputsCheckForCollaborators) True
          pure $ githubAccessTokenNixConfig $ repoInfo' ^. ghToken
      | isJust $ commitInfo ^. prFromFork ->
          throw
            $ OtherError
              "Repository has private dependencies, but PR is from fork."
```

The private-self-repo collaborator gate (`FlakeInputAuthorization.hs:135-150`) already has no `selfHost` term, so it keeps running. Private-cache output routing is preserved.

- [ ] **Step 2: Compile gate.**

Run: `nix build .#backend_garnixHaskellPackage --no-link --print-out-paths`
Expected: exit 0. (This change is integration-only for tests — `authorizeGithubPrivateInputs` needs the GitHub-interface + DB harness; the pure parsers in `FlakeInputAuthorizationSpec.hs` are unaffected.)

- [ ] **Step 3: Commit.**

```bash
git -C ~/Development/garnix-ci add backend/src/Garnix/FlakeInputAuthorization.hs
git -C ~/Development/garnix-ci commit -m "backend(flake-auth): keep private-input collaborator gate in self-host mode (M4)"
```

---

## Task 4: M5 (on-demand-check cache) + stats source gate (Hosts.hs)

Both edit `Garnix/API/Hosts.hs` and share the module-header/import block, so they land together. Stats gate consumes `guestSubnetPrefix` from Task 1.

**Files:**
- Modify: `backend/src/Garnix/API/Hosts.hs`
- Modify: `backend/test/spec/SpecHook.hs` (clear the new cache between specs)
- Test: `backend/test/spec/Garnix/API/HostsSpec.hs`

**Interfaces:**
- Consumes: Env `selfHostMode`, `guestSubnetPrefix`; `Garnix.ExpiringCache` (`mkCache`/`lookupCache`/`clearCache`); `Network.Socket`.
- Produces (for SpecHook/tests): exports `__onDemandDomainsCache`, `postHostsStatsGuarded`, `statsSourceAllowed`.

- [ ] **Step 1: Write failing pure tests for `statsSourceAllowed`.** In `HostsSpec.hs` add `import Network.Socket (SockAddr (..), tupleToHostAddress)` and:

```haskell
      describe "statsSourceAllowed" $ do
        let guestPeer = SockAddrInet 5555 (tupleToHostAddress (10, 111, 0, 82))
            loopback = SockAddrInet 5555 (tupleToHostAddress (127, 0, 0, 1))
            outside = SockAddrInet 5555 (tupleToHostAddress (203, 0, 113, 7))
        it "accepts a direct bridge peer" $
          statsSourceAllowed "10.111.0." guestPeer Nothing `shouldBe` True
        it "accepts a proxied guest via X-Forwarded-For" $
          statsSourceAllowed "10.111.0." loopback (Just "10.111.0.82") `shouldBe` True
        it "uses the last (proxy-appended) forwarded entry" $
          statsSourceAllowed "10.111.0." loopback (Just "10.111.0.9, 203.0.113.7") `shouldBe` False
        it "rejects a loopback peer without a forwarded client" $
          statsSourceAllowed "10.111.0." loopback Nothing `shouldBe` False
        it "rejects an outside peer with a forged header" $
          statsSourceAllowed "10.111.0." outside (Just "10.111.0.82") `shouldBe` False
```

- [ ] **Step 2: Update the module header/exports/imports.** Replace the export list (`Hosts.hs:1-10`) with:

```haskell
module Garnix.API.Hosts
  ( getHostsForTraefik,
    postHostsHeartbeat,
    postHostsStats,
    postHostsStatsGuarded,
    statsSourceAllowed,
    hostsAPI,
    HostsAPI,
    getHosts,
    HostList (..),
    -- exported for tests (SpecHook clears it between specs)
    __onDemandDomainsCache,
  )
where
```

Add imports (alphabetical): `import Garnix.Duration`, `import Garnix.ExpiringCache`, `import System.IO.Unsafe qualified`, `import Network.Socket (SockAddr (..), hostAddress6ToTuple, hostAddressToTuple)`. Change `import Data.Maybe (mapMaybe)` (Hosts.hs:17) to `import Data.Maybe (listToMaybe, mapMaybe)`.

- [ ] **Step 3: Add the memoized on-demand cache; replace `onDemandCheck` (`Hosts.hs:331-336`).** Leave `getDomainsForOnDemandResolver` uncached. Add:

```haskell
-- | Process-local memo of the routable-domain set for the Caddy on_demand_tls
-- "ask" endpoint. Every unknown-SNI TLS handshake hits 'onDemandCheck', so an
-- SNI flood would otherwise amplify into three DB queries per handshake; the
-- 10s TTL mirrors the on-demand-resolver sidecar's FETCH_INTERVAL
-- (hosting-gateway/on-demand-resolver/src/lib.ts). Module-level
-- (unsafePerformIO + NOINLINE) is the codebase's established cache pattern —
-- see Garnix.API.Cache.Permissions.__getRepoPermissionsCache. Unnamed so a
-- flood doesn't also amplify into per-request cache log lines.
type OnDemandDomainsCache = ExpiringCache () OnDemandResolverDomainNames

{-# NOINLINE __onDemandDomainsCache #-}
__onDemandDomainsCache :: OnDemandDomainsCache
__onDemandDomainsCache =
  System.IO.Unsafe.unsafePerformIO
    $ mkCache Nothing (fromSeconds @Int 10) (fromSeconds @Int 2)

onDemandCheck :: Maybe Text -> M NoContent
onDemandCheck mDomain = do
  OnDemandResolverDomainNames names <-
    lookupCache __onDemandDomainsCache () getDomainsForOnDemandResolver
  case mDomain of
    Just d | d `elem` names -> pure NoContent
    _ -> throw NotFound
```

- [ ] **Step 4: Add the stats source gate.** Change the route type (`Hosts.hs:32-39`) to add `RemoteHost` + the `X-Forwarded-For` header:

```haskell
    _hostsAPIPostStats :: route :- "stats" :> RemoteHost :> Header "X-Forwarded-For" Text :> ReqBody '[JSON] HostStatsReport :> Post '[JSON] NoContent,
```

Change the wiring (`Hosts.hs:63`) `_hostsAPIPostStats = postHostsStats,` → `_hostsAPIPostStats = postHostsStatsGuarded,`. Keep `postHostsStats` unchanged and add after it:

```haskell
-- | Source gate for guest stats pushes, active in self-host mode only. The
-- backend listens on 127.0.0.1 behind Caddy, so the TCP peer of a proxied
-- request is always loopback; the guest's real address is what Caddy saw,
-- delivered in X-Forwarded-For (Caddy replaces any client-supplied value with
-- the actual peer address, and only Caddy can reach the loopback listener).
-- Accept a sample iff the effective client is in the guest bridge subnet:
-- either the peer itself (a direct bridge listener), or a loopback peer whose
-- X-Forwarded-For client is.
postHostsStatsGuarded :: SockAddr -> Maybe Text -> HostStatsReport -> M NoContent
postHostsStatsGuarded peer mForwardedFor report = do
  selfHost <- view #selfHostMode
  when selfHost $ do
    prefix <- view #guestSubnetPrefix
    unless (statsSourceAllowed prefix peer mForwardedFor)
      $ throw
      $ ForbiddenWithMessage "stats: source address not in the guest subnet"
  postHostsStats report

-- | Pure decision for 'postHostsStatsGuarded'; exported for tests. The
-- forwarded client is the LAST X-Forwarded-For entry — the one appended by
-- the proxy we trust (Caddy strips untrusted inbound values entirely, so in
-- practice it is the only entry).
statsSourceAllowed :: Text -> SockAddr -> Maybe Text -> Bool
statsSourceAllowed guestPrefix peer mForwardedFor =
  inGuestSubnet peerIp || (isLoopback peerIp && inGuestSubnet forwardedClientIp)
  where
    peerIp = sockAddrIPv4 peer
    forwardedClientIp = do
      xff <- mForwardedFor
      listToMaybe (reverse (map T.strip (T.splitOn "," xff)))
    inGuestSubnet = maybe False (guestPrefix `T.isPrefixOf`)
    isLoopback = maybe False ("127." `T.isPrefixOf`)

-- | Render an IPv4 (or IPv4-mapped IPv6) socket address as dotted decimal.
sockAddrIPv4 :: SockAddr -> Maybe Text
sockAddrIPv4 = \case
  SockAddrInet _ addr ->
    let (a, b, c, d) = hostAddressToTuple addr
     in Just $ T.intercalate "." (map (cs . show) [a, b, c, d])
  SockAddrInet6 _ _ addr _ ->
    case hostAddress6ToTuple addr of
      (0, 0, 0, 0, 0, 0xffff, hi, lo) ->
        Just
          $ T.intercalate "."
          $ map (cs . show) [hi `div` 256, hi `mod` 256, lo `div` 256, lo `mod` 256]
      _ -> Nothing
  _ -> Nothing
```

- [ ] **Step 5: Clear the new cache between specs.** In `backend/test/spec/SpecHook.hs` add `import Garnix.API.Hosts qualified` and extend the `before_` clearing block with `>> clearCache Garnix.API.Hosts.__onDemandDomainsCache`.

- [ ] **Step 6: (optional) add an on-demand-check HTTP test** in `HostsSpec.hs` (add `import Garnix.ExpiringCache (clearCache)`):

```haskell
      describe "/api/hosts/on-demand-check" $ do
        it "200s for a routable domain and 404s otherwise" $ do
          user <- testUser
          void
            $ createServer
              (GhRepoOwner $ GhLogin "owner")
              (GhRepoName "repo")
              (Branch "branch")
              Nothing
              (PackageName "foo")
              Nothing
              user
              identity
          clearCache __onDemandDomainsCache
          withServer $ \testServer -> do
            ok <- testServer.get "/api/hosts/on-demand-check?domain=foo.branch.repo.owner.garnix.me"
            ok `shouldHaveStatusCode` 200
            bad <- testServer.get "/api/hosts/on-demand-check?domain=nope.example.com"
            bad `shouldHaveStatusCode` 404
```

(Adjust the expected domain suffix to the deployed `hostingDomain`.)

- [ ] **Step 7: Compile gate.**

Run: `nix build .#backend_garnixHaskellPackage --no-link --print-out-paths`
Expected: exit 0.

- [ ] **Step 8: Commit.**

```bash
git -C ~/Development/garnix-ci add backend/src/Garnix/API/Hosts.hs backend/test/spec/SpecHook.hs backend/test/spec/Garnix/API/HostsSpec.hs
git -C ~/Development/garnix-ci commit -m "backend(hosts): memoize on-demand-check (M5); guest-subnet gate /api/hosts/stats"
```

---

## Task 5: M3 (proxy-provenance marker) + JWT TTL (Auth.hs)

Both edit `Auth.hs` and touch `loginCallback`/`signupCallback`/`finishSignup`. **Apply M3 first (header threading), then JWT-TTL (swaps the `cookieSettings'` binding line) — the hunks are disjoint.** M3 consumes `proxySharedSecret` from Task 1.

**Files:**
- Modify: `backend/src/Garnix/API/Auth.hs`
- Test: `backend/test/spec/Garnix/API/AuthSpec.hs`

**Interfaces:**
- Consumes: Env `selfHostMode`, `proxySharedSecret`, `cookieSettings`, `jwtSettings`.
- Contract to Caddy (Task 19): Caddy injects `X-Garnix-Proxy-Auth: <secret>` on the gated `@api` proxy and strips it inbound; the secret file is delivered to the backend as `GARNIX_PROXY_SHARED_SECRET_FILE`.

- [ ] **Step 1: Write failing pure tests for `selfHostProxyMarkerOk`.** In `AuthSpec.hs`, extend the import on line 13 with `selfHostProxyMarkerOk` and add:

```haskell
    describe "selfHostProxyMarkerOk" $ do
      it "always passes outside self-host mode" $ do
        selfHostProxyMarkerOk False Nothing Nothing `shouldBe` True
        selfHostProxyMarkerOk False (Just "s") Nothing `shouldBe` True
      it "passes when the configured secret matches the header" $
        selfHostProxyMarkerOk True (Just "s3kr1t") (Just "s3kr1t") `shouldBe` True
      it "rejects a wrong or missing header" $ do
        selfHostProxyMarkerOk True (Just "s3kr1t") (Just "nope") `shouldBe` False
        selfHostProxyMarkerOk True (Just "s3kr1t") Nothing `shouldBe` False
      it "fails closed when no secret is configured" $ do
        selfHostProxyMarkerOk True Nothing (Just "anything") `shouldBe` False
        selfHostProxyMarkerOk True (Just "") (Just "") `shouldBe` False
```

- [ ] **Step 2: Add the marker helper + rework `requireSelfHostAuth`.** Keep `selfHostLoginAllowed`/`subscriptionTypeForGroups` as-is; replace the existing `requireSelfHostAuth` (`Auth.hs:70-78`) and add above it:

```haskell
-- | Whether the request provably traversed the authenticating gateway: in
-- self-host mode the gateway injects @X-Garnix-Proxy-Auth: <secret>@ on every
-- request it forwards (and strips any client-supplied value), and the backend
-- compares it against its own copy of the secret. Fail-closed in self-host
-- mode: no configured secret, or a missing/wrong header, rejects. Outside
-- self-host mode it always passes. Defense-in-depth: the CI sandbox is already
-- network-isolated (bwrap --unshare-net + nix sandbox), so this guards other
-- local/loopback reachability of the backend.
selfHostProxyMarkerOk :: Bool -> Maybe Text -> Maybe Text -> Bool
selfHostProxyMarkerOk selfHost mConfiguredSecret mMarkerHeader
  | not selfHost = True
  | otherwise = case (mConfiguredSecret, mMarkerHeader) of
      (Just secret, Just marker) -> not (T.null secret) && secret == marker
      _ -> False

-- | Reject a login that did not come through the authenticating gateway when
-- running in self-host mode: the gateway must have injected both the groups
-- header and the shared-secret marker. A no-op outside self-host mode.
requireSelfHostAuth :: Maybe Text -> Maybe Text -> M ()
requireSelfHostAuth mGroupsHeader mProxyAuthHeader = do
  selfHost <- view #selfHostMode
  mSecret <- view #proxySharedSecret
  unless
    ( selfHostLoginAllowed selfHost mGroupsHeader
        && selfHostProxyMarkerOk selfHost mSecret mProxyAuthHeader
    )
    $ throw
    $ ForbiddenWithMessage "Login requires the authentication gateway."
```

- [ ] **Step 3: Thread the new header through the three routes + handlers.** In each of `_loginAPILoginCallback`, `_signupAPISignupCallback`, `_signupAPIFinishSignup`, insert directly under the `:> Header "X-Auth-Request-Groups" Text` line:

```haskell
        :> Header "X-Garnix-Proxy-Auth" Text
```

Then add a `Maybe Text` parameter to `loginCallback`, `signupCallback`, `finishSignup` (named `mProxyAuth`) and change each first line from `requireSelfHostAuth mGroupsHeader` to `requireSelfHostAuth mGroupsHeader mProxyAuth`. The `finishSignup` fallback clause becomes `finishSignup _ _ _ _ = throw $ OtherError "Did not receive expected user info"`. (Signatures gain one `Maybe Text ->`; bodies otherwise unchanged.)

- [ ] **Step 4: Add the session JWT TTL (30m).** Update the `Servant.Auth.Server` import to add `CookieSettings (..)` and add `import Data.Time.Clock (secondsToDiffTime)`. Add:

```haskell
-- | TTL of a freshly minted browser session: both the JWT @exp@ claim and the
-- cookie Max-Age. Upstream leaves 'cookieExpires' at 'Nothing', which mints
-- session JWTs with NO expiry — a captured cookie stays valid until the JWT
-- key rotates, and the admin/subscription snapshot inside it never refreshes.
-- 30 minutes bounds both; the oauth2-proxy in front re-checks Authentik group
-- membership on its own cookie refresh independently.
sessionJwtTtl :: NominalDiffTime
sessionJwtTtl = 30 * 60

-- | The Env cookie settings with expiry stamped relative to now.
-- servant-auth-server's 'acceptLogin' uses 'cookieExpires' verbatim as the
-- JWT @exp@, so this must be computed per login rather than at startup.
sessionCookieSettings :: M CookieSettings
sessionCookieSettings = do
  cookieSettings' <- view #cookieSettings
  now <- liftIO getCurrentTime
  pure
    $ cookieSettings'
      { cookieExpires = Just (addUTCTime sessionJwtTtl now),
        cookieMaxAge = Just (secondsToDiffTime (round sessionJwtTtl))
      }
```

Then replace `cookieSettings' <- view #cookieSettings` with `cookieSettings' <- sessionCookieSettings` in exactly three handlers: `loginCallback` (~line 258), `signupCallback` (~line 303), `finishSignup` (~line 362). Leave `logout`'s `view #cookieSettings` alone.

- [ ] **Step 5: Compile gate.**

Run: `nix build .#backend_garnixHaskellPackage --no-link --print-out-paths`
Expected: exit 0.

- [ ] **Step 6: Commit.**

```bash
git -C ~/Development/garnix-ci add backend/src/Garnix/API/Auth.hs backend/test/spec/Garnix/API/AuthSpec.hs
git -C ~/Development/garnix-ci commit -m "backend(auth): proxy-provenance marker (M3); 30m session JWT TTL"
```

---

## Task 6: Forge-aware deployer keys + M1 redeploy re-copy (Deploy.hs)

Two Deploy.hs changes land together (one compile unit): forge-aware deployer key fetch, and the M1 backend half (re-deliver the repo key on redeploy, since `/var/garnix/keys` becomes tmpfs in Task 10 — RAM-only, gone on power-cycle).

**Files:**
- Modify: `backend/src/Garnix/Hosting/Deploy.hs:466-497` and the call site `Deploy.hs:285-290` (forge-aware); `Deploy.hs:321-329` `redeployServer` (M1).

**Interfaces:**
- Consumes: `commitInfo ^. repoInfo . forge :: Forge`, Env `giteaConfig :: Maybe GiteaConfig` (`_giteaConfigBaseUrl`); `copyKeys :: RepoInfo -> ServerInfo -> M ()` (already in scope), `commitInfo ^. repoInfo`.
- Pairs with: Task 10 Step 5 (the `/var/garnix/keys` tmpfs mount) — M1 is only complete with both halves.

- [ ] **Step 1: Replace `copyAuthorizedKeys` + `fetchGithubKeys` (`Deploy.hs:466-497`)** with the forge-aware version:

```haskell
-- | Authorize login as the guest's `garnix` user by dropping an authorized_keys
-- file the guest profile reads via authorizedKeys.keyFiles. Keys are the
-- deployer's forge keys (best-effort, only when a deployer is given) plus the
-- explicit authorizedSSHKeys. No-op with no keys.
copyAuthorizedKeys :: Forge -> ServerInfo -> Maybe GhLogin -> [Text] -> M ()
copyAuthorizedKeys forge' server mDeployer extraKeys = do
  forgeKeys <- maybe (pure []) (fetchDeployerKeys forge') mDeployer
  let keys = filter (not . T.null . T.strip) (forgeKeys <> extraKeys)
  unless (null keys) $ do
    (ip, sshArgs) <- ServerPool.sshArgsFor server
    let keyFile = "/var/garnix/keys/authorized_keys" :: Text
    (exitCode, _, _) <-
      liftIO
        $ Proc.readProcessWithExitCode
          "ssh"
          ((cs <$> sshArgs) <> ["root@" <> cs ip, "mkdir -p /var/garnix/keys && cat > " <> cs keyFile <> " && chmod 444 " <> cs keyFile])
          (cs (T.unlines keys))
    case exitCode of
      ExitSuccess -> pure ()
      ExitFailure _ -> throw $ OtherError "Writing authorized_keys to the server failed"

-- | The deployer's public SSH keys, via the forge's @<login>.keys@ endpoint —
-- github.com for GitHub repos, the configured Gitea instance for Gitea repos
-- (both forges serve the same URL shape). Best-effort: any failure (network,
-- 404, a Gitea with REQUIRE_SIGNIN_VIEW, missing Gitea config) yields no keys.
fetchDeployerKeys :: Forge -> GhLogin -> M [Text]
fetchDeployerKeys forge' login =
  ( do
      mBaseUrl <- case forge' of
        ForgeGithub -> pure $ Just "https://github.com"
        ForgeGitea -> fmap _giteaConfigBaseUrl <$> view #giteaConfig
      case mBaseUrl of
        Nothing -> pure []
        Just baseUrl -> do
          resp <-
            withWreqOptions $ \opts ->
              Wreq.getWith opts (cs (baseUrl <> "/" <> getGhLogin login <> ".keys"))
          pure $ filter (not . T.null . T.strip) $ T.lines $ cs (resp ^. Wreq.responseBody)
  )
    `catchAny` const (pure [])
```

- [ ] **Step 2: Update the call site (`Deploy.hs:285-290`)** to pass the forge:

```haskell
      when authorizesGarnixUser
        $ copyAuthorizedKeys
          (commitInfo ^. repoInfo . forge)
          serverInfo
          (if serverToSpinUp ^. #authorizeDeployerGithubKeys then Just (commitInfo ^. reqUser) else Nothing)
          (serverToSpinUp ^. #authorizedSSHKeys)
        <?> "Authorizing SSH keys"
```

- [ ] **Step 3: M1 — re-deliver the repo key on redeploy.** In `redeployServer` (`Deploy.hs:321-329`), replace the `copyClosure … "Copying closure for redeployment"` line with:

```haskell
        -- /var/garnix/keys is a tmpfs on the guest (see guest-profile.nix), so
        -- the repo key is RAM-only and vanishes if the VM ever power-cycles.
        -- Re-deliver it on every redeploy so decrypting services restarted by
        -- switch-to-configuration always find it. Idempotent on healthy guests.
        copyKeys (commitInfo ^. repoInfo) serverInfo <?> "Copying repo key"
        copyClosure (SshUser "garnix") serverInfo storePath <?> "Copying closure for redeployment"
```

(`copyKeys` is unchanged — `mkdir -p` on the active mountpoint is a no-op and `cat >`/`chmod 400` behave identically on tmpfs. Root ssh works on redeployed guests — the profile always authorizes the hosting key for root.)

- [ ] **Step 4: Compile gate.**

Run: `nix build .#backend_garnixHaskellPackage --no-link --print-out-paths`
Expected: exit 0. Existing `DeploySpec.hs` tests cover both paths ("deploys the repo key…" ~line 243; "report redeployment of persistent server" ~line 439). (Integration-only for `fetchDeployerKeys` itself; verify with a real Gitea-repo deploy in Task 20.)

- [ ] **Step 5: Commit.**

```bash
git -C ~/Development/garnix-ci add backend/src/Garnix/Hosting/Deploy.hs
git -C ~/Development/garnix-ci commit -m "backend(deploy): forge-aware deployer key fetch; re-copy repo key on redeploy (M1)"
```

---

## Task 7: Backend NixOS module — new option knobs + env wiring

Adds the options the aspect sets and wires their env vars. Eval-checked with the aspect (Phase 3); the Haskell gate does not cover it.

**Files:**
- Modify: `backend/nixos-module.nix` (options block ~line 153-162; env `environment` list ~line 543-545).

**Interfaces:**
- Produces options: `services.garnixServer.proxySharedSecretFile`, `.terminalCaKeyPath`, `.terminalSourceAddress` → env `GARNIX_PROXY_SHARED_SECRET_FILE`, `GARNIX_TERMINAL_CA_KEY`, `GARNIX_TERMINAL_SOURCE_ADDRESS`.

- [ ] **Step 1: Add the three options** after `sshHost` (`backend/nixos-module.nix:153-162`):

```nix
        proxySharedSecretFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/run/secrets/garnix_proxy_shared_secret";
          description = ''
            File containing the shared secret the trusted reverse proxy injects
            as the X-Garnix-Proxy-Auth request header. In selfHostMode the
            backend only honors X-Auth-Request-* identity headers when the
            request carries this header with the file's (trailing-whitespace-
            trimmed) contents. Sets GARNIX_PROXY_SHARED_SECRET_FILE; when null
            the backend falls back to /run/secrets/garnix_proxy_shared_secret.
            The secret VALUE is deliberately never placed in the unit
            environment (unit properties are world-readable via systemctl show).
          '';
        };
        terminalCaKeyPath = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/run/secrets/garnix_terminal_ca";
          description = ''
            Path to a dedicated SSH CA private key used ONLY to sign the
            short-lived web-terminal session certificates (Garnix.API.Terminal).
            Guests trust its public key as TrustedUserCAKeys, so the
            hosting/deploy key stops being a certificate mint and this CA key
            grants no direct login. Sets GARNIX_TERMINAL_CA_KEY; when null the
            backend falls back to /run/secrets/garnix_terminal_ca. If that file
            is absent the web terminal fails closed (no hosting-key fallback).
          '';
        };
        terminalSourceAddress = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "10.111.0.1/32";
          description = ''
            CIDR the backend bakes into web-terminal certs as
            `-O source-address` (GARNIX_TERMINAL_SOURCE_ADDRESS): the host's own
            address on the guest bridge, so a minted cert only authenticates
            from the backend. null omits the restriction.
          '';
        };
```

- [ ] **Step 2: Wire the env vars** — after the `sshHost` optional in the `environment` list (`backend/nixos-module.nix:543-545`):

```nix
        ++ lib.optionals (config.services.garnixServer.proxySharedSecretFile != null) [
          "GARNIX_PROXY_SHARED_SECRET_FILE=${config.services.garnixServer.proxySharedSecretFile}"
        ]
        ++ lib.optionals (config.services.garnixServer.terminalCaKeyPath != null) [
          "GARNIX_TERMINAL_CA_KEY=${config.services.garnixServer.terminalCaKeyPath}"
        ]
        ++ lib.optionals (config.services.garnixServer.terminalSourceAddress != null) [
          "GARNIX_TERMINAL_SOURCE_ADDRESS=${config.services.garnixServer.terminalSourceAddress}"
        ]
```

- [ ] **Step 3: Syntax check.**

Run: `nix-instantiate --parse ~/Development/garnix-ci/backend/nixos-module.nix >/dev/null && echo OK`
Expected: `OK` (full eval happens with the aspect in Phase 3).

- [ ] **Step 4: Commit.**

```bash
git -C ~/Development/garnix-ci add backend/nixos-module.nix
git -C ~/Development/garnix-ci commit -m "backend(module): options for proxy secret, terminal CA, terminal source-address"
```

---

# Phase 2 — Provisioner (Nix + Python)

## Task 8: `provisioner/nixos-module.nix` — isolation hook, sysctls, egress ACL, terminal-CA derivation, options

All edits to one file (C1a hook, C1b/M6/M8 sysctls, H5 egress ACL, H3 terminal-CA derivation, options + env + doc fixes). Verify by parse + full eval with the aspect (Phase 3).

**Files:**
- Modify: `provisioner/nixos-module.nix`

**Interfaces:**
- Consumes: `microvm.nixosModules.host` (imported by the aspect); `pkgs.iproute2`, `pkgs.openssh`, `pkgs.writeShellScript`.
- Produces: option `garnix.local-provisioner.terminalCaPrivateKeyPath` (str, default `/run/secrets/garnix_terminal_ca`); `guestEgressBlocklist` (list of CIDR); `guestCpuModel` (nullOr str); daemon env `PROVISIONER_TERMINAL_CA_PUBKEY_FILE`, `PROVISIONER_PORT_RANGE_END`, `PROVISIONER_GUEST_CPU`; the guest tap name `gx<id>` enslaved to `garnixbr0` with `isolated on`.

- [ ] **Step 1: Add the derived-pubkey `let` binding.** Replace `provisioner/nixos-module.nix:21-22`:

```nix
  stateDir = "/var/lib/garnix-provisioner";
  pubkeyPath = "${stateDir}/hosting.pub";
  # Dedicated web-terminal CA public key (finding H3), derived at service start
  # from cfg.terminalCaPrivateKeyPath and baked into every guest as its
  # TrustedUserCAKeys (NOT the hosting/deploy key).
  terminalCaPubkeyPath = "${stateDir}/terminal-ca.pub";
```

- [ ] **Step 2: Add the `terminalCaPrivateKeyPath` and `guestCpuModel` options** after `sshPrivateKeyPath` (`nixos-module.nix:50-57`):

```nix
    terminalCaPrivateKeyPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/garnix_terminal_ca";
      description = ''
        The dedicated web-terminal certificate-authority private key (finding
        H3), separate from the hosting/deploy key. The matching public key is
        derived at service start and baked into every guest as its
        TrustedUserCAKeys, so the backend's short-lived terminal-session certs
        are trusted WITHOUT the guest trusting the hosting key as a CA. If the
        secret is absent at start the derivation falls back to the hosting
        pubkey so the daemon still starts and guests stay evaluable.
      '';
    };
    guestCpuModel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "IvyBridge";
      description = ''
        QEMU CPU model for guests (microvm.cpu). null (default) keeps
        microvm.nix's `-cpu host` passthrough. A fixed named model narrows
        the host-feature/side-channel surface a guest can see, at the cost
        of hiding newer ISA extensions from guest code. Must be a model the
        host CPU can satisfy (erdtree: dual E5-2667 v2 = IvyBridge;
        IvyBridge-IBRS if the microcode exposes spec-ctrl).
      '';
    };
```

- [ ] **Step 3: Add the `guestEgressBlocklist` option** after `exposePortRange` (`nixos-module.nix:117`):

```nix
    guestEgressBlocklist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
        "169.254.0.0/16"
        "100.64.0.0/10"
      ];
      example = [ "10.0.0.0/8" "192.168.0.0/16" "147.224.12.5/32" ];
      description = ''
        Destination CIDRs guests can never initiate connections to (FORWARD
        drop before NAT). The default covers RFC1918 + link-local + CGNAT,
        which includes the guest bridge subnet itself and the host LAN.
        NOTE: setting this option replaces the default — repeat the ranges
        you still want and append internal hosts that are NOT in private
        space (e.g. a remote builder's public address).
      '';
    };
```

- [ ] **Step 4: Fix the now-inaccurate port-base option docs** (`nixos-module.nix:89-104`):

```nix
    sshExposePortBase = lib.mkOption {
      type = lib.types.int;
      default = 22000;
      description = ''
        Bottom of the host-port pool for per-VM SSH exposure (garnix.yaml
        sshExpose). Ports are allocated lowest-free from
        [sshExposePortBase, tcpExposePortBase) and recorded per guest.
      '';
    };
    tcpExposePortBase = lib.mkOption {
      type = lib.types.int;
      default = 32000;
      description = ''
        Bottom of the host-port pool for per-VM raw-tcp exposure (garnix.yaml
        ports type=tcp). Ports are allocated lowest-free from
        [tcpExposePortBase, exposePortRange.to] and recorded per guest.
      '';
    };
```

- [ ] **Step 5: Add the tap-isolation ExecStartPost drop-in.** Inside `config = lib.mkIf cfg.enable { … }`, after the firewall block (before dnsmasq):

```nix
    # ── Guest<->guest isolation at L2 (bridge port isolation) ─────────────────
    # Guest specs use `type = "tap"` interfaces named gx<id>. microvm.nix's
    # microvm-tap-interfaces@<vm> template creates the tap but attaches it to
    # nothing; this ExecStartPost drop-in enslaves it to the guest bridge as an
    # ISOLATED port. Isolated ports may talk to the bridge device itself (host:
    # dnsmasq DHCP, Traefik, backend ssh, NAT) but never to another isolated
    # port — killing guest->guest unicast, ARP/ND spoofing and rogue RA/DHCP at
    # L2, independent of the bridge-nf-call-* sysctls. Ordering is race-free:
    # microvm@%i is After= this oneshot, which only completes once
    # ExecStartPost has run. Non-garnix microVMs on the host are untouched.
    systemd.services."microvm-tap-interfaces@".serviceConfig.ExecStartPost = [
      "${pkgs.writeShellScript "garnix-tap-isolate" ''
        set -euo pipefail
        case "$1" in
          garnix-*) ;;
          *) exit 0 ;;
        esac
        tap="gx''${1#garnix-}"
        ${pkgs.iproute2}/bin/ip link set dev "$tap" master ${cfg.bridge}
        ${pkgs.iproute2}/bin/ip link set dev "$tap" type bridge_slave isolated on
      ''} %i"
    ];
```

- [ ] **Step 6: Add the pinned sysctl block (C1b + M6 + M8) + assertion.** Replace the "Deliberately NOT disabling the bridge-nf-call-*" comment (`nixos-module.nix:182-185`) with:

```nix
    # Pin bridge-nf-call-*: the FORWARD DROP above only sees bridged
    # guest<->guest traffic while br_netfilter routes it through iptables, and
    # this sysctl has been observed flipping 0<->1 at runtime (docker & friends
    # touch it). Pin it ON declaratively. This is belt only — the real
    # guest<->guest barrier is bridge port isolation (the
    # microvm-tap-interfaces@ hook above), which works at L2 regardless.
    boot.kernelModules = [ "br_netfilter" ];
    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
      # M8: never process router advertisements arriving on the guest bridge
      # (a guest could otherwise announce itself as an IPv6 router to the
      # host). systemd's udev rule re-applies per-interface sysctls when the
      # bridge appears, so this survives the interface being created late.
      "net.ipv6.conf.${cfg.bridge}.accept_ra" = 0;
      # M6: the DNAT exposure range (exposePortRange, default 22000-41999)
      # overlaps the kernel's default ephemeral range (32768-60999), so a host
      # outbound connection could occupy a port the daemon DNATs. Move the
      # ephemeral range above the exposed range (defaults: "42000 60999").
      # Tradeoff: ~19000 ephemeral ports instead of ~28000 — ample here.
      "net.ipv4.ip_local_port_range" = "${toString (cfg.exposePortRange.to + 1)} 60999";
    };
    assertions = [
      {
        assertion = cfg.exposePortRange.to < 60000;
        message = "garnix.local-provisioner.exposePortRange.to must stay below 60000 so an ephemeral port range remains above it.";
      }
    ];
```

- [ ] **Step 7: Add the egress ACL (H5).** Replace the guest↔guest isolation comment + `extraCommands`/`extraStopCommands` (`nixos-module.nix:163-181`) with:

```nix
    # Isolate guests from one another: drop forwarding between two ports of the
    # guest bridge, so a compromised guest can't reach its neighbours (the pool
    # VM, another tenant's app). Host<->guest is INPUT/OUTPUT (unaffected) and
    # guest->internet is `-i bridge -o uplink` (see the egress ACL below).
    # Primary guest<->guest isolation is bridge PORT ISOLATION (the
    # microvm-tap-interfaces@ hook above); this FORWARD rule and the pinned
    # bridge-nf-call-* sysctls are belt.
    networking.firewall.extraCommands = ''
      # delete-then-insert so a reload can't accumulate duplicates
      iptables  -D FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP 2>/dev/null || true
      iptables  -I FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP
      ip6tables -D FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP 2>/dev/null || true
      ip6tables -I FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP 2>/dev/null || true

      # Guest egress ACL (H5): guests may reach the internet but not the LAN,
      # RFC1918/link-local space, or configured internal hosts. Replies to
      # host-/DNAT-initiated inbound connections stay allowed via conntrack
      # (so a LAN client using an exposed DNAT port still gets answers).
      # A dedicated chain, flushed and rebuilt every reload, stays idempotent.
      iptables -D FORWARD -i ${cfg.bridge} -j garnix-guest-egress 2>/dev/null || true
      iptables -F garnix-guest-egress 2>/dev/null || true
      iptables -X garnix-guest-egress 2>/dev/null || true
      iptables -N garnix-guest-egress
      iptables -A garnix-guest-egress -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      ${lib.concatMapStrings (cidr: ''
        iptables -A garnix-guest-egress -d ${cidr} -j DROP
      '') cfg.guestEgressBlocklist}
      iptables -A garnix-guest-egress -j RETURN
      # Position 2: after the bridge<->bridge DROP just inserted at position 1,
      # and ahead of the NAT module's `-i bridge -o uplink -j ACCEPT` (which
      # lives in nixos-filter-forward, appended at the FORWARD tail).
      iptables -I FORWARD 2 -i ${cfg.bridge} -j garnix-guest-egress

      # Guests are IPv4-only (DHCPv4, RA refused): no bridged IPv6 is ever
      # legitimately forwarded, so drop it wholesale instead of mirroring
      # the v4 ACL.
      ip6tables -D FORWARD -i ${cfg.bridge} -j DROP 2>/dev/null || true
      ip6tables -I FORWARD -i ${cfg.bridge} -j DROP 2>/dev/null || true
    '';
    networking.firewall.extraStopCommands = ''
      iptables  -D FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP 2>/dev/null || true
      ip6tables -D FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP 2>/dev/null || true
      iptables  -D FORWARD -i ${cfg.bridge} -j garnix-guest-egress 2>/dev/null || true
      iptables  -F garnix-guest-egress 2>/dev/null || true
      iptables  -X garnix-guest-egress 2>/dev/null || true
      ip6tables -D FORWARD -i ${cfg.bridge} -j DROP 2>/dev/null || true
    '';
```

- [ ] **Step 8: Extend `ExecStartPre` to derive the terminal-CA pubkey (H3).** Replace the `ExecStartPre` block (`nixos-module.nix:246-250`):

```nix
        ExecStartPre = pkgs.writeShellScript "garnix-provisioner-pubkey" ''
          set -euo pipefail
          ${pkgs.openssh}/bin/ssh-keygen -y -f ${cfg.sshPrivateKeyPath} > ${pubkeyPath}
          chmod 0644 ${pubkeyPath}
          # Dedicated web-terminal CA public key (finding H3): guests trust THIS
          # as TrustedUserCAKeys, not the hosting key. Fall back to the hosting
          # pubkey if the terminal-CA secret isn't installed, so the daemon still
          # starts and guests stay evaluable (the Python side mirrors this).
          if ${pkgs.openssh}/bin/ssh-keygen -y -f ${cfg.terminalCaPrivateKeyPath} > ${terminalCaPubkeyPath} 2>/dev/null; then
            :
          else
            cp ${pubkeyPath} ${terminalCaPubkeyPath}
          fi
          chmod 0644 ${terminalCaPubkeyPath}
        '';
```

- [ ] **Step 9: Add the three daemon env vars.** In the `environment = { … }` block, replace the `PROVISIONER_SSH_PUBKEY_FILE = pubkeyPath;` line (`nixos-module.nix:236`) with:

```nix
        PROVISIONER_SSH_PUBKEY_FILE = pubkeyPath;
        PROVISIONER_TERMINAL_CA_PUBKEY_FILE = terminalCaPubkeyPath;
        PROVISIONER_PORT_RANGE_END = toString cfg.exposePortRange.to;
        PROVISIONER_GUEST_CPU = if cfg.guestCpuModel == null then "" else cfg.guestCpuModel;
```

- [ ] **Step 10: Syntax + eval check.**

Run: `nix-instantiate --parse ~/Development/garnix-ci/provisioner/nixos-module.nix >/dev/null && echo PARSE_OK`
Expected: `PARSE_OK`. Full eval is deferred to the aspect dry-run in Task 17 Step 4.

- [ ] **Step 11: Commit.**

```bash
git -C ~/Development/garnix-ci add provisioner/nixos-module.nix
git -C ~/Development/garnix-ci commit -m "provisioner(module): tap isolation (C1/M8), pinned sysctls (C1b/M6/M8), egress ACL (H5), terminal-CA derivation (H3)"
```

---

## Task 9: `provisioner/provisionerd.py` — tap spec, terminal-CA emit, CPU, DNAT free-list

**Files:**
- Modify: `provisioner/provisionerd.py`

**Interfaces:**
- Consumes env: `PROVISIONER_TERMINAL_CA_PUBKEY_FILE`, `PROVISIONER_PORT_RANGE_END`, `PROVISIONER_GUEST_CPU` (Task 8).
- Produces: guests with `type = "tap"` named `gx<id>` (Task 8's hook isolates them); `garnix.guest.terminalCaPublicKey` in each spec; collision-free DNAT.

- [ ] **Step 1: Add the module-level constants.** After `TCP_PORTS_PER_VM = 20` (line 60) add:

```python
# Inclusive top of the host DNAT port range (exposePortRange.to on the host).
PORT_RANGE_END = int(os.environ.get("PROVISIONER_PORT_RANGE_END", "41999"))
```

After `STATS_URL` (line 46) add:

```python
# Optional fixed QEMU CPU model for guests (microvm.cpu). Empty = -cpu host.
GUEST_CPU = os.environ.get("PROVISIONER_GUEST_CPU", "")
```

After `SSH_PUBKEY_FILE = os.environ["PROVISIONER_SSH_PUBKEY_FILE"]` (line 42) add:

```python
# Dedicated web-terminal CA public key (finding H3). Guests trust THIS as their
# TrustedUserCAKeys, not the hosting key. Optional: if unset/absent/empty we
# fall back to the hosting pubkey in write_spec, so guests stay evaluable and
# keep trusting the hosting key as CA (pre-H3 behaviour / ExecStartPre fallback).
TERMINAL_CA_PUBKEY_FILE = os.environ.get("PROVISIONER_TERMINAL_CA_PUBKEY_FILE", "")
```

- [ ] **Step 2: Read the terminal-CA pubkey content in `write_spec`.** Replace the hosting-pubkey read (`provisionerd.py:101-102`):

```python
    with open(SSH_PUBKEY_FILE) as f:
        pubkey = f.read().strip()
    # Web-terminal CA pubkey (H3). Fall back to the hosting pubkey if the
    # dedicated CA pubkey file is unset/absent/empty, so guests stay evaluable
    # and keep trusting the hosting key as CA until the pool is recycled.
    terminal_ca_pubkey = pubkey
    if TERMINAL_CA_PUBKEY_FILE:
        try:
            with open(TERMINAL_CA_PUBKEY_FILE) as f:
                _tca = f.read().strip()
            if _tca:
                terminal_ca_pubkey = _tca
        except FileNotFoundError:
            pass
```

- [ ] **Step 3: Replace the consolidated `guest.nix` emission** (`provisionerd.py:127-142`) — flips the interface to `type = "tap"` (C1a), adds the optional CPU line (low/info), and injects `terminalCaPublicKey` (H3):

```python
    with open(os.path.join(spec_dir, "guest.nix"), "w") as f:
        # `type = "tap"` (not "bridge"): the bridge-helper netdev creates an
        # anonymous kernel-named tap the host can't target. A named tap
        # (gx<id>, created by microvm-tap-interfaces@) lets the host enslave
        # it to the bridge as an ISOLATED port (see nixos-module.nix), which
        # blocks guest<->guest at L2 regardless of bridge-nf-call-* sysctls.
        cpu_line = f"  microvm.cpu = {nix_str(GUEST_CPU)};\n" if GUEST_CPU else ""
        f.write(
            f"""{{
  imports = [ ./guest-profile.nix ];
  networking.hostName = {nix_str(name)};
  microvm.vcpu = {vcpu};
  microvm.mem = {mem};
{cpu_line}  microvm.interfaces = [
    {{ type = "tap"; id = {nix_str(f"gx{vm_id}")}; mac = {nix_str(vm_mac(vm_id))}; }}
  ];
  garnix.guest.sshPublicKey = {nix_str(pubkey)};
  garnix.guest.terminalCaPublicKey = {nix_str(terminal_ca_pubkey)};
  garnix.guest.statsReportUrl = {nix_str(STATS_URL)};
  garnix.guest.provisionerId = {vm_id};
}}
"""
        )
```

(`bridge = null` is implicit by omitting the attr; microvm.nix's `type = "tap"` requires it absent.)

- [ ] **Step 4: Add the DNAT free-list helpers.** After `del_dnat` (line 213) add:

```python
def _list_rules(table, chain: str) -> list:
    """Parse `iptables [-t table] -S <chain>` into arg-lists (['-A', chain, ...])."""
    cmd = ["iptables"]
    if table:
        cmd += ["-t", table]
    cmd += ["-S", chain]
    res = run(cmd, check=False)
    rules = []
    for line in (res.stdout or "").splitlines():
        parts = line.split()
        if parts[:2] == ["-A", chain]:
            rules.append(parts)
    return rules


def flush_host_port_rules(host_port: int):
    """Delete EVERY uplink PREROUTING rule for this host port, whatever guest
    it pointed at — stale DNATs from crashed daemons or prior tenants must
    never linger behind a fresh expose."""
    for parts in _list_rules("nat", "PREROUTING"):
        if (
            "--dport" in parts
            and parts[parts.index("--dport") + 1] == str(host_port)
            and "-i" in parts
            and parts[parts.index("-i") + 1] == UPLINK
        ):
            run(["iptables", "-t", "nat", "-D"] + parts[1:], check=False)


def flush_forward_accepts(guest_ip: str):
    """Delete every FORWARD ACCEPT aimed at this guest IP (stale entries from
    an earlier VM that held the same deterministic IP)."""
    for parts in _list_rules(None, "FORWARD"):
        if (
            "-d" in parts
            and parts[parts.index("-d") + 1] == f"{guest_ip}/32"
            and parts[-1] == "ACCEPT"
        ):
            run(["iptables", "-D"] + parts[1:], check=False)


def allocated_host_ports(exclude: str = "") -> set:
    """Union of host ports recorded for live guests (the EXPOSED_DIR state
    files double as the on-disk port registry; destroy deletes a guest's file
    and thereby frees its ports)."""
    used = set()
    try:
        entries = os.listdir(EXPOSED_DIR)
    except FileNotFoundError:
        return used
    for fn in entries:
        if not fn.endswith(".json") or fn == f"{exclude}.json":
            continue
        try:
            with open(os.path.join(EXPOSED_DIR, fn)) as f:
                state = json.load(f)
        except (OSError, ValueError):
            continue
        for rule in state.get("rules", []):
            used.add(int(rule["host"]))
    return used


def alloc_host_port(used: set, lo: int, hi: int, preferred=None) -> int:
    """Lowest free port in [lo, hi], preferring this VM's previous port so
    re-exposing stays stable. Marks the result used."""
    if preferred is not None and lo <= preferred <= hi and preferred not in used:
        used.add(preferred)
        return preferred
    for port in range(lo, hi + 1):
        if port not in used:
            used.add(port)
            return port
    raise RuntimeError(f"no free host port in {lo}-{hi}")
```

- [ ] **Step 5: Replace `do_expose`** (`provisionerd.py:304-331`) with the free-list version:

```python
def do_expose(req: dict) -> dict:
    """Publish a guest's SSH and/or tcp ports on the host via DNAT. Host ports
    come from a free-list over the exposure registry (EXPOSED_DIR), preferring
    the VM's previous ports so re-exposing is stable; any stale rule on a
    chosen host port is flushed before the fresh DNAT is added. Response:
      {"ssh_port": Int|null, "tcp_ports": [{"guest": Int, "host": Int}, ...]}."""
    vm_id = int(req["id"])
    name = vm_name(vm_id)
    ip = vm_ip(vm_id)
    ssh_expose = bool(req.get("ssh_expose", False))
    tcp_ports = [int(p) for p in req.get("tcp_ports", [])]
    with mutate_lock:
        # Remember this VM's previous allocation before wiping it.
        preferred = {}
        prev_ssh = None
        try:
            with open(_exposure_path(name)) as f:
                prev = json.load(f)
            for rule in prev.get("rules", []):
                if int(rule["guest"]) == 22:
                    prev_ssh = int(rule["host"])
                else:
                    preferred[int(rule["guest"])] = int(rule["host"])
        except (FileNotFoundError, ValueError):
            pass
        # Re-exposing replaces prior rules (idempotent), including any strays
        # aimed at this guest IP from an earlier tenant of the same id slot.
        remove_exposure(name)
        flush_forward_accepts(ip)
        used = allocated_host_ports(exclude=name)
        rules = []
        ssh_port = None
        if ssh_expose:
            ssh_port = alloc_host_port(used, SSH_PORT_BASE, TCP_PORT_BASE - 1, preferred=prev_ssh)
            flush_host_port_rules(ssh_port)
            add_dnat(ssh_port, ip, 22)
            rules.append({"host": ssh_port, "guest": 22})
        tcp_result = []
        for guest in tcp_ports[:TCP_PORTS_PER_VM]:
            host_port = alloc_host_port(used, TCP_PORT_BASE, PORT_RANGE_END, preferred=preferred.get(guest))
            flush_host_port_rules(host_port)
            add_dnat(host_port, ip, guest)
            rules.append({"host": host_port, "guest": guest})
            tcp_result.append({"guest": guest, "host": host_port})
        write_exposure(name, ip, rules)
    log.info("exposed %s: ssh_port=%s tcp=%s", name, ssh_port, tcp_result)
    return {"ssh_port": ssh_port, "tcp_ports": tcp_result}
```

(If `_exposure_path` is not the existing helper name, use whatever `write_exposure`/`remove_exposure` use to locate a guest's JSON — match the existing code.)

- [ ] **Step 6: Verify (unit tests land in Task 11).** Quick sanity now:

Run: `python3 -c "import ast; ast.parse(open('/home/joe/Development/garnix-ci/provisioner/provisionerd.py').read()); print('PARSE_OK')"`
Expected: `PARSE_OK`.

- [ ] **Step 7: Commit.**

```bash
git -C ~/Development/garnix-ci add provisioner/provisionerd.py
git -C ~/Development/garnix-ci commit -m "provisioner(daemon): tap interfaces + isolation, terminal-CA pubkey emit, DNAT free-list, optional CPU model"
```

---

## Task 10: `provisioner/guest-profile.nix` — firewall, IPv4-only/RA, terminal-CA trust

**Files:**
- Modify: `provisioner/guest-profile.nix`

**Interfaces:**
- Consumes: `garnix.guest.sshPublicKey` (existing), the injected `garnix.guest.terminalCaPublicKey` (Task 9).
- Produces: guest option `garnix.guest.terminalCaPublicKey`; `TrustedUserCAKeys` sourced from it; guest firewall on; IPv4-only + RA refused.

- [ ] **Step 1: Add the `terminalCaPublicKey` guest option** after `sshPublicKey` (`guest-profile.nix:47-50`):

```nix
    terminalCaPublicKey = lib.mkOption {
      type = lib.types.str;
      default = config.garnix.guest.sshPublicKey;
      description = ''
        Public key of the dedicated web-terminal certificate authority (finding
        H3), trusted as TrustedUserCAKeys so the backend can mint short-lived
        per-session login certs WITHOUT the guest trusting the hosting/deploy
        key as a CA. Defaults to sshPublicKey for backward compatibility: guests
        deployed before H3 (and user flakes that don't set it) keep trusting the
        hosting key as CA. The provisioner injects the real terminal-CA pubkey.
      '';
    };
```

- [ ] **Step 2: Point `TrustedUserCAKeys` at the terminal CA (H3).** Replace `guest-profile.nix:116-129` (the doc + `environment.etc."ssh/garnix-hosting-ca.pub"` + `services.openssh.extraConfig`):

```nix
    # Trust the DEDICATED web-terminal certificate authority (finding H3) as a
    # user-certificate authority — NOT the hosting/deploy key. This lets the
    # backend mint short-lived, per-session SSH certificates (signed by the
    # terminal CA) to open the web terminal directly as any declared login user
    # (e.g. `joe`), while the hosting key stays purely a deploy/login identity.
    # Splitting the CA from the hosting key means a terminal-CA compromise can
    # only mint terminal certs (bounded by the login-user principal the backend
    # sets), and does NOT hand out the standing root/deploy key. The certs are
    # minted on demand by the backend and expire within the terminal-session
    # window. The file keeps its historical name; its content is now the
    # terminal CA. terminalCaPublicKey defaults to the hosting key, so guests
    # deployed before H3 stay evaluable and keep working until recreated.
    environment.etc."ssh/garnix-hosting-ca.pub".text = config.garnix.guest.terminalCaPublicKey + "\n";
    services.openssh.extraConfig = ''
      TrustedUserCAKeys /etc/ssh/garnix-hosting-ca.pub
      Match User garnix
        AuthorizedKeysFile .ssh/authorized_keys /var/garnix/keys/authorized_keys
      Match all
    '';
```

**Do NOT change** `guest-profile.nix:130` and `:135` — root's and garnix's `authorizedKeys.keys = [ config.garnix.guest.sshPublicKey ]` stay on the hosting key (the deploy/login identity).

- [ ] **Step 3: Enable the guest firewall (C1c).** Replace `guest-profile.nix:141-142`:

```nix
    # Guests live on a host-only bridge, but they run deployed (semi-trusted)
    # code next to neighbours — keep the firewall ON as containment hygiene.
    # 22 is the deploy/sshExpose path; 80 is the common Traefik http target
    # (the hello example). Deployed configs that serve on other ports
    # (garnix.yaml servers[].ports) must open them themselves — the standard
    # option merges with this one:
    #   networking.firewall.allowedTCPPorts = [ 3000 ];
    # mkDefault so a guest config can still opt out explicitly.
    networking.firewall = {
      enable = lib.mkDefault true;
      allowedTCPPorts = [ 22 80 ];
    };
```

- [ ] **Step 4: IPv4-only + refuse RA (C1d/M8).** Replace `guest-profile.nix:96-100`:

```nix
    networking.useNetworkd = true;
    systemd.network.networks."10-eth" = {
      matchConfig.Type = "ether";
      # IPv4-only: the provisioner's dnsmasq (per-MAC reservations) is the
      # single source of addressing truth. Never accept router advertisements
      # — on a shared bridge an RA is how a neighbour impersonates the
      # gateway (M8). Host-side bridge port isolation already stops
      # guest->guest RA/DHCP at L2; this is guest-side belt.
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = false;
      };
    };
    boot.kernel.sysctl = {
      "net.ipv6.conf.all.accept_ra" = 0;
      "net.ipv6.conf.default.accept_ra" = 0;
    };
```

- [ ] **Step 5: M1 — mount `/var/garnix/keys` as tmpfs.** The repo secret-decryption key (and `default-authentik.env`, `authorized_keys`) are deploy-delivered here; a tmpfs keeps them RAM-only, never written to the persistent `root.img`. Insert immediately **after** the `microvm = { … };` block (after `guest-profile.nix:115`'s closing `};`, before `networking.useNetworkd = true;`):

```nix
    # Deploy-delivered key material (repo-key, default-authentik.env,
    # authorized_keys) lives in RAM only: a tmpfs over /var/garnix/keys means
    # the repo's secret-decryption key is never written to the persistent
    # root.img, so a copied/backed-up/leaked disk image can't yield it (M1).
    # The backend delivers all three files post-boot over ssh (copyKeys /
    # copyDefaultAuthentikEnv / copyAuthorizedKeys), so the mount — active
    # since local-fs.target, long before sshd — is always in place first.
    # mode=0755 (not 0700) because sshd opens
    # /var/garnix/keys/authorized_keys with the garnix user's uid, so the
    # directory must stay world-traversable; the secrets themselves remain
    # root-only via their file modes (repo-key 0400). Guests configure no
    # swap, so the pages can't be written out.
    fileSystems."/var/garnix/keys" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=0755" "size=4m" ];
    };
```

Also add one bullet to the fixed-conventions header list (after the `overlay.img` bullet, `guest-profile.nix:9`):

```nix
#   - /var/garnix/keys on tmpfs (deploy-delivered keys are RAM-only, never
#     at rest on the disk images)
```

**Note (existing contract):** the profile header already requires the base guest and every user `nixosConfiguration` to share this profile so fstab matches. A user repo pinning an **older** `garnix-ci` input would, on switch, drop this mount unit and evaporate the just-delivered keys mid-deploy — so bump the `garnix-ci` input in deployed repos in tandem with the host upgrade.

- [ ] **Step 6: Syntax check.**

Run: `nix-instantiate --parse ~/Development/garnix-ci/provisioner/guest-profile.nix >/dev/null && echo PARSE_OK`
Expected: `PARSE_OK`.

- [ ] **Step 7: Commit.**

```bash
git -C ~/Development/garnix-ci add provisioner/guest-profile.nix
git -C ~/Development/garnix-ci commit -m "provisioner(guest): firewall on (C1c), IPv4-only + RA-refuse (C1d/M8), terminal-CA TrustedUserCAKeys (H3), /var/garnix/keys tmpfs (M1)"
```

---

## Task 11: Provisioner port-allocator unit tests

**Files:**
- Create: `provisioner/test_provisionerd_ports.py`
- Modify: `provisioner/default.nix` (add a `checks` entry)

**Interfaces:**
- Consumes: `provisionerd.alloc_host_port`, `.allocated_host_ports`, `.EXPOSED_DIR` (Task 9).

- [ ] **Step 1: Write the test file.** Create `provisioner/test_provisionerd_ports.py`:

```python
#!/usr/bin/env python3
"""Unit tests for provisionerd's host-port allocator + registry. provisionerd
reads PROVISIONER_* env at import time, so required vars are pinned first;
no iptables/network is touched (pure helpers only)."""
import json
import os
import tempfile
import unittest

os.environ.setdefault("PROVISIONER_SOCKET", "/tmp/test-provisioner.sock")
os.environ.setdefault("PROVISIONER_NIXPKGS", "path:/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-src")
os.environ.setdefault("PROVISIONER_MICROVM", "path:/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-src")
os.environ.setdefault("PROVISIONER_GUEST_PROFILE", "/dev/null")
os.environ.setdefault("PROVISIONER_SSH_PUBKEY_FILE", "/dev/null")

import provisionerd as pd


class AllocTests(unittest.TestCase):
    def test_lowest_free(self):
        used = {22000, 22001}
        self.assertEqual(pd.alloc_host_port(used, 22000, 31999), 22002)
        self.assertIn(22002, used)

    def test_preferred_wins(self):
        self.assertEqual(pd.alloc_host_port(set(), 22000, 31999, preferred=22007), 22007)

    def test_preferred_taken_falls_back_to_lowest(self):
        self.assertEqual(pd.alloc_host_port({22007}, 22000, 31999, preferred=22007), 22000)

    def test_exhausted_raises(self):
        with self.assertRaises(RuntimeError):
            pd.alloc_host_port({22000}, 22000, 22000)


class RegistryTests(unittest.TestCase):
    def test_union_and_exclude(self):
        with tempfile.TemporaryDirectory() as d:
            old = pd.EXPOSED_DIR
            pd.EXPOSED_DIR = d
            try:
                with open(os.path.join(d, "garnix-1.json"), "w") as f:
                    json.dump({"ip": "10.111.0.11", "rules": [{"host": 22000, "guest": 22}]}, f)
                with open(os.path.join(d, "garnix-2.json"), "w") as f:
                    json.dump({"ip": "10.111.0.12", "rules": [{"host": 32000, "guest": 80}]}, f)
                self.assertEqual(pd.allocated_host_ports(), {22000, 32000})
                self.assertEqual(pd.allocated_host_ports(exclude="garnix-1"), {32000})
            finally:
                pd.EXPOSED_DIR = old


if __name__ == "__main__":
    unittest.main()
```

(Pin any other `PROVISIONER_*` vars `provisionerd.py` reads unconditionally at import — check the top of the module and add matching `os.environ.setdefault` lines.)

- [ ] **Step 2: Run it directly to confirm it passes.**

Run: `cd ~/Development/garnix-ci/provisioner && python3 -m unittest test_provisionerd_ports -v`
Expected: all tests PASS. (If import fails on a missing `PROVISIONER_*`, add its `setdefault`.)

- [ ] **Step 3: Wire the nix check.** In `provisioner/default.nix`, add alongside `authentikProvisionTests`:

```nix
    provisionerdPortTests = pkgs.runCommand "provisionerd-port-tests"
      { nativeBuildInputs = [ pkgs.python3 ]; } ''
      cp ${./provisionerd.py} provisionerd.py
      cp ${./test_provisionerd_ports.py} test_provisionerd_ports.py
      python3 -m unittest test_provisionerd_ports -v
      touch "$out"
    '';
```

- [ ] **Step 4: `git add` the new file, then gate via nix.**

```bash
git -C ~/Development/garnix-ci add provisioner/test_provisionerd_ports.py provisioner/default.nix
```
Run: `nix build .#checks.x86_64-linux.provisionerdPortTests`
Expected: exit 0.

- [ ] **Step 5: Commit.**

```bash
git -C ~/Development/garnix-ci commit -m "provisioner(test): host-port allocator + registry unit tests (M7)"
```

---

# Phase 3 — Dotfiles aspect + secrets

> After the fork commits (Phases 1–2) are pushed, in `~/dotfiles` run
> `set -x NIX_CONFIG "access-tokens = github.com=$(gh auth token)"; nix flake update garnix-ci`
> so the aspect builds against the new fork code before deploying. Do this once the fork is pushed (Task 22 Step 1 lists the exact order).

## Task 12: Create the three new agenix secrets

**Files:**
- Modify: `~/dotfiles-secrets/secrets.nix`
- Create: `~/dotfiles-secrets/garnix-proxy-shared-secret.age`, `garnix-terminal-ca.age`, `garnix-terminal-ca-pub.age`

- [ ] **Step 1: Add recipients.** In `~/dotfiles-secrets/secrets.nix`, after the gitea entries (`secrets.nix:107-108`) add:

```nix
  # Proxy-provenance marker: Caddy injects this as X-Garnix-Proxy-Auth on
  # gated requests to the backend; the backend only trusts X-Auth-Request-*
  # identity headers when it matches (loopback alone is not provenance).
  "garnix-proxy-shared-secret.age".publicKeys = users ++ [ erdtree ];
  # Dedicated web-terminal SSH CA (H3): the backend signs short-lived session
  # certs with the private key; guests trust ONLY the public key as
  # TrustedUserCAKeys. Splits cert-minting off the hosting/deploy key.
  "garnix-terminal-ca.age".publicKeys = users ++ [ erdtree ];
  "garnix-terminal-ca-pub.age".publicKeys = users ++ [ erdtree ];
```

- [ ] **Step 2: Create the proxy secret (stdin; no trailing newline hazard).** From `~/dotfiles-secrets`:

```bash
openssl rand -base64 48 | tr -d '\n' | agenix -e garnix-proxy-shared-secret.age
```

- [ ] **Step 3: Create the terminal CA keypair (stdin).** From `~/dotfiles-secrets`:

```bash
tmp=$(mktemp -d)
ssh-keygen -t ed25519 -N '' -C garnix-terminal-ca -f "$tmp/ca"
agenix -e garnix-terminal-ca.age     < "$tmp/ca"
agenix -e garnix-terminal-ca-pub.age < "$tmp/ca.pub"
shred -u "$tmp/ca"; rm -rf "$tmp"
```

- [ ] **Step 4: Commit + push, then bump the input.**

```bash
git -C ~/dotfiles-secrets add -A
git -C ~/dotfiles-secrets commit -m "garnix: proxy shared secret + dedicated terminal CA"
git -C ~/dotfiles-secrets push
```
Then in `~/dotfiles` (fish): `set -x NIX_CONFIG "access-tokens = github.com=$(gh auth token)"; nix flake update dotfiles-secrets`
Expected: the three `.age` files exist and `dotfiles-secrets` input is updated.

- [ ] **Step 5: Commit the input bump.**

```bash
git -C ~/dotfiles add flake.lock
git -C ~/dotfiles commit -m "flake: bump dotfiles-secrets (garnix proxy secret + terminal CA)"
```

---

## Task 13: `garnix.nix` — install new secrets, per-secret groups, key modes, fluent-bit group (M2 + low-info)

**Files:**
- Modify: `~/dotfiles/modules/hosts/erdtree/garnix.nix`

**Interfaces:**
- Consumes: agenix secrets from Task 12.
- Produces: `/run/secrets/garnix_proxy_shared_secret` (garnix:garnix-proxy-auth 0440), `/run/secrets/garnix_terminal_ca` (garnix:garnix 0400), `/run/secrets/garnix_terminal_ca_pub` (0440); groups `garnix-opensearch`, `garnix-proxy-auth`.

- [ ] **Step 1: Add the three secrets to `garnixSecrets`.** Replace the `garnixSecrets` tail (`garnix.nix:54-58`, the gitea entries + closing `};`):

```nix
        # Gitea forge integration: bot API token + webhook HMAC secret. The
        # backend reads /run/secrets/gitea-token + /run/secrets/gitea-webhook-secret.
        "gitea-token" = "garnix-gitea-token.age";
        "gitea-webhook-secret" = "garnix-gitea-webhook-secret.age";
        # Proxy-provenance marker (M3): injected by Caddy as X-Garnix-Proxy-Auth
        # on gated backend requests; validated by the backend before trusting
        # X-Auth-Request-*. Group garnix-proxy-auth so the caddy user can read
        # it at request time ({file.*} placeholder).
        "garnix_proxy_shared_secret" = "garnix-proxy-shared-secret.age";
        # Dedicated web-terminal CA (H3). Private key 0400 (ssh-keygen refuses
        # group-readable keys); guests trust the public key as
        # TrustedUserCAKeys instead of the hosting key.
        "garnix_terminal_ca" = "garnix-terminal-ca.age";
        "garnix_terminal_ca_pub" = "garnix-terminal-ca-pub.age";
      };
```

- [ ] **Step 2: Rework the `age.secrets` mapping — per-secret groups + expanded 0400 set.** Replace `garnix.nix:152-169`:

```nix
      age.secrets = (lib.mapAttrs'
        (name: file: lib.nameValuePair "garnix-${name}" {
          file = "${dotfiles-secrets}/${file}";
          path = "/run/secrets/${name}";
          symlink = false;
          owner = "garnix";
          # Per-secret groups instead of blanket `garnix` where a non-backend
          # service needs read access — membership in `garnix` would grant that
          # service every 0440 backend secret:
          #  - opensearch-garnix: backend reads as OWNER; fluent-bit gets the
          #    dedicated garnix-opensearch group (belt-and-braces — its module
          #    reads via LoadCredential, i.e. as root).
          #  - garnix_proxy_shared_secret: caddy resolves it per-request via a
          #    {file.*} placeholder, so the caddy user reads it directly.
          group =
            if name == "opensearch-garnix" then "garnix-opensearch"
            else if name == "garnix_proxy_shared_secret" then "garnix-proxy-auth"
            else "garnix";
          # SSH private keys the backend (garnix user) uses as an ssh identity —
          # into guest microVMs (hosting key), into the local action-runner
          # user (action-runner key), to remote builders (remote-builder key) —
          # plus the terminal-signing CA. OpenSSH refuses a private key that is
          # group-readable when the caller owns it, so these must be 0400 (not
          # the blanket 0440 the other garnix secrets use).
          mode =
            if lib.elem name [
              "garnix_server_ssh_hosting"
              "garnix_action_runner_ssh"
              "garnix_server_remote_builder_ssh"
              "garnix_terminal_ca"
            ]
            then "0400"
            else "0440";
        })
        garnixSecrets)
```

- [ ] **Step 3: Create the two new groups.** Insert before `networking.hosts."127.0.0.1" = [ dbFqdn ];` (`garnix.nix:187`):

```nix
      # Scoped secret-access groups (see age.secrets above).
      users.groups.garnix-opensearch = { };
      users.groups.garnix-proxy-auth.members = [ "caddy" ];
```

- [ ] **Step 4: Move fluent-bit off `garnix` (M2).** Replace the fluent-bit block (`garnix.nix:192-204`):

```nix
        fluent-bit = {
          enable = true;
          # Scoped group for the opensearch password ONLY (not `garnix`, which
          # would grant read on every 0440 backend secret). Strictly the module
          # reads the password via LoadCredential (service manager, as root),
          # so no group is needed at all — this is defense-in-depth in case the
          # module ever switches to a direct read.
          extraGroups = [ "garnix-opensearch" ];
          opensearch = {
            fqdn = "localhost";
            port = 9200;
            tls = false;
            basicAuth = {
              username = "garnix";
              passwordFile = "/run/secrets/opensearch-garnix";
            };
          };
        };
```

- [ ] **Step 5: Order caddy after agenix (so the proxy-secret file exists on boot).** Add near the other ordering blocks (~`garnix.nix:424-427`):

```nix
      systemd.services.caddy = {
        after = [ "agenix.service" ];
        wants = [ "agenix.service" ];
      };
```

- [ ] **Step 6: Eval probe.**

Run (fish, from `~/dotfiles`): `set -x NIX_CONFIG "access-tokens = github.com=$(gh auth token)"; nix eval .#nixosConfigurations.erdtree.config.users.groups.garnix-opensearch --apply builtins.typeOf`
Expected: `"set"` (evaluates without error). Full toplevel dry-run in Task 22.

- [ ] **Step 7: Commit.**

```bash
git -C ~/dotfiles add modules/hosts/erdtree/garnix.nix
git -C ~/dotfiles commit -m "garnix(secrets): install proxy secret + terminal CA; scoped groups; fluent-bit off garnix group (M2); remote-builder key 0400"
```

---

## Task 14: `garnix.nix` — Caddy proxy-marker inject + `@stats` gate + `services.garnixServer` settings (M3, stats, H3/H2 wiring)

**Files:**
- Modify: `~/dotfiles/modules/hosts/erdtree/garnix.nix`

**Interfaces:**
- Contract to backend: header `X-Garnix-Proxy-Auth`, secret file `/run/secrets/garnix_proxy_shared_secret`; the backend reads `GARNIX_PROXY_SHARED_SECRET_FILE` (set via `services.garnixServer.proxySharedSecretFile`), `GARNIX_TERMINAL_CA_KEY` (via `terminalCaKeyPath`), `GARNIX_TERMINAL_SOURCE_ADDRESS` (via `terminalSourceAddress`).

- [ ] **Step 1: Strip the marker inbound on both vhosts.** In the app vhost (`garnix.nix:540-543`) and the cache vhost strip (`garnix.nix:616-619`), add a fourth strip line:

```nix
          request_header -X-Garnix-Proxy-Auth
```

(Both vhosts now strip `-X-Auth-Request-User/-Email/-Groups` and `-X-Garnix-Proxy-Auth`.)

- [ ] **Step 2: Inject the marker on the gated `@api` proxy.** Replace the gated `handle { … }` block (`garnix.nix:601-613`):

```nix
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
            reverse_proxy @api 127.0.0.1:8321 {
              # Proxy-provenance marker: proves this request traversed the
              # forward_auth gate (a loopback source alone is not provenance —
              # any local process can hit :8321). {file.*} is read per-request
              # by the caddy user (group garnix-proxy-auth); trailing newline
              # is trimmed; a missing file sends an empty value, which the
              # backend rejects (fails closed).
              header_up X-Garnix-Proxy-Auth {file./run/secrets/garnix_proxy_shared_secret}
            }
            reverse_proxy 127.0.0.1:3000
          }
```

(The unauthenticated bypass handles — `@webhook @publickeys @badges @artifacts @stats` and the cache vhost — deliberately do NOT carry the marker; those routes never consult `X-Auth-Request-*`.)

- [ ] **Step 3: Gate `@stats` to the guest subnet (defense-in-depth for the backend check).** In the `@stats` matcher (`garnix.nix:576-579`), add a `remote_ip` condition so only bridge sources hit the ungated path. Replace the matcher + handler:

```nix
          @stats {
            path /api/hosts/stats
            remote_ip 10.111.0.0/24
          }
          reverse_proxy @stats 127.0.0.1:8321
```

(The backend `statsSourceAllowed` check from Task 4 is the authority; this reduces the ungated surface. Confirm the app domain is grey-clouded so guests reach Caddy as `10.111.0.x` — Task 22 verification.)

- [ ] **Step 4: Wire the backend settings.** In the `services.garnixServer` block, after `sshHost = domains.erdtreeSshDomain;` (`garnix.nix:315`), add:

```nix
        # Proxy-provenance marker file (M3): Caddy injects its contents as
        # X-Garnix-Proxy-Auth after forward_auth; the backend requires a match
        # before trusting X-Auth-Request-* headers.
        proxySharedSecretFile = "/run/secrets/garnix_proxy_shared_secret";
        # Dedicated terminal-signing CA (H3) — split from the hosting key.
        terminalCaKeyPath = "/run/secrets/garnix_terminal_ca";
        # Terminal cert source-address pin (H2): the host's own address on the
        # guest bridge (garnix.provisioner.hostAddress = 10.111.0.1/24).
        terminalSourceAddress = "10.111.0.1/32";
```

- [ ] **Step 5: Eval probe.**

Run (fish, `~/dotfiles`): `nix eval .#nixosConfigurations.erdtree.config.services.garnixServer.terminalCaKeyPath`
Expected: `"/run/secrets/garnix_terminal_ca"`.

- [ ] **Step 6: Commit.**

```bash
git -C ~/dotfiles add modules/hosts/erdtree/garnix.nix
git -C ~/dotfiles commit -m "garnix(caddy): inject X-Garnix-Proxy-Auth (M3); guest-subnet @stats gate; wire terminal CA + source-address"
```

---

## Task 15: `garnix.nix` — provisioner settings (terminal CA pass-down, egress blocklist, optional CPU model)

**Files:**
- Modify: `~/dotfiles/modules/hosts/erdtree/garnix.nix` (the `garnix.local-provisioner` block, ~line 434-447)

- [ ] **Step 1: Add the provisioner settings.** In the `garnix.local-provisioner = { … };` block, add:

```nix
        # Dedicated terminal-signing CA (H3): the daemon derives its PUBLIC key
        # at start and injects it into guests as garnix.guest.terminalCaPublicKey
        # (TrustedUserCAKeys), so guests no longer trust the hosting key as a
        # certificate authority.
        terminalCaPrivateKeyPath = "/run/secrets/garnix_terminal_ca";
        # Guest egress ACL (H5): block RFC1918 + link-local + CGNAT (default)
        # AND the aarch64 remote builder farum-azula (public IP, not RFC1918).
        guestEgressBlocklist = [
          "10.0.0.0/8"
          "172.16.0.0/12"
          "192.168.0.0/16"
          "169.254.0.0/16"
          "100.64.0.0/10"
          "147.224.12.5/32"
        ];
```

- [ ] **Step 2 (optional): Pin a fixed guest CPU model.** Only if you accept guests losing newer ISA extensions (erdtree = IvyBridge):

```nix
        guestCpuModel = "IvyBridge";
```

Leave it unset to keep `-cpu host`. **Recommendation:** skip unless you specifically want the side-channel narrowing; note guests must be recreated to pick it up.

- [ ] **Step 3: Eval probe.**

Run (fish, `~/dotfiles`): `nix eval .#nixosConfigurations.erdtree.config.garnix.local-provisioner.guestEgressBlocklist`
Expected: the list including `"147.224.12.5/32"`.

- [ ] **Step 4: Commit.**

```bash
git -C ~/dotfiles add modules/hosts/erdtree/garnix.nix
git -C ~/dotfiles commit -m "garnix(provisioner): terminal-CA pass-down (H3), egress blocklist incl. remote builder (H5)"
```

---

## Task 16 (OPTIONAL, flagged): Edge L7 rate-limiting

Stock nixpkgs caddy 2.11.4 has **no `rate_limit` module** — this requires building caddy with the `mholt/caddy-ratelimit` plugin (a TOFU vendor-hash step). Skip unless you want L7 rate limits; it does not block production readiness. Guest-router rate limits belong in the backend-generated Traefik config (not implemented here).

**Files:**
- Modify: `~/dotfiles/modules/hosts/erdtree/garnix.nix`

- [ ] **Step 1: Build caddy with the plugin (TOFU).** Add near the caddy config:

```nix
      # L7 rate limiting needs the (non-standard) mholt/caddy-ratelimit module;
      # stock nixpkgs caddy does not ship it, so build caddy with the plugin.
      # TOFU: first build fails with "got: sha256-..." — paste that hash here.
      services.caddy.package = pkgs.caddy.withPlugins {
        plugins = [ "github.com/mholt/caddy-ratelimit@v0.1.0" ];
        hash = lib.fakeHash;
      };
```

- [ ] **Step 2: Order the directive + add the app-vhost limit.** Replace `services.caddy.globalConfig` (`garnix.nix:515-519`):

```nix
      services.caddy.globalConfig = ''
        # Non-standard directive (mholt/caddy-ratelimit): must be ordered.
        order rate_limit before basic_auth
        on_demand_tls {
          ask http://127.0.0.1:8321/api/hosts/on-demand-check
        }
      '';
```

And after the app-vhost `request_header` strips (`garnix.nix:540-543` + the marker strip) add:

```nix
          rate_limit {
            zone garnix_app {
              key {client_ip}
              events 600
              window 1m
            }
          }
```

Do **not** rate-limit the cache vhost (nix substitution makes many narinfo requests) or the on-demand catch-all (TLS handshakes aren't HTTP-handler-throttleable; that surface is issuance-gated).

- [ ] **Step 3: TOFU the hash.** `nix build .#nixosConfigurations.erdtree.config.system.build.toplevel` → copy the `got: sha256-…` into `hash =`, rebuild.

- [ ] **Step 4: Commit.**

```bash
git -C ~/dotfiles add modules/hosts/erdtree/garnix.nix
git -C ~/dotfiles commit -m "garnix(caddy): optional L7 rate-limit via caddy-ratelimit plugin"
```

---

# Phase 4 — Deploy, migrate, verify

## Task 17: Push the fork, bump the input, full eval, deploy

- [ ] **Step 1: Push the fork (all Phase 1–2 commits).**

```bash
git -C ~/Development/garnix-ci push origin main
```

- [ ] **Step 2: Bump the fork input in dotfiles.**

Run (fish, `~/dotfiles`): `set -x NIX_CONFIG "access-tokens = github.com=$(gh auth token)"; nix flake update garnix-ci`
Then commit: `git -C ~/dotfiles add flake.lock && git -C ~/dotfiles commit -m "flake: bump garnix-ci (hosting hardening)"`

- [ ] **Step 3: Full backend gate + provisioner test gate (from the fork).**

```bash
cd ~/Development/garnix-ci && nix build .#backend_garnixHaskellPackage --no-link --print-out-paths && nix build .#checks.x86_64-linux.provisionerdPortTests
```
Expected: both exit 0.

- [ ] **Step 4: Full aspect eval (dry-run).**

Run (fish, `~/dotfiles`): `set -x NIX_CONFIG "access-tokens = github.com=$(gh auth token)"; nix build .#nixosConfigurations.erdtree.config.system.build.toplevel --dry-run`
Expected: evaluates and plans a build with no eval errors (assertion for `exposePortRange.to < 60000` passes).

- [ ] **Step 5: Deploy (between builds — this restarts `garnixServer`).** Confirm no long build is in flight first (`ssh erdtree sudo -u postgres psql -p 9178 -d garnix -c "SELECT package,status FROM builds WHERE status IS NULL AND end_time IS NULL;"`). Then:

```bash
cd ~/dotfiles && just build-to-erdtree
```
Expected: deploy succeeds; `ssh erdtree systemctl status garnixServer` active.

---

## Task 18: One-time DB migration — re-gate private inputs (M4)

The old code persisted `skip_private_inputs_check_for_collaborators = true` for every self-host public repo, so the new gate is a no-op until those rows are cleaned. Keep `private_cache = true` (closures already live in the authenticated bucket).

- [ ] **Step 1: Inspect current repo_config.**

```bash
ssh erdtree sudo -u postgres psql -p 9178 -d garnix -c "SELECT repo_user, repo_name, skip_private_inputs_check_for_collaborators, private_cache FROM repo_config;"
```

- [ ] **Step 2: Clear the auto-set flag** (then re-grant per repo via the admin API only where intended):

```bash
ssh erdtree sudo -u postgres psql -p 9178 -d garnix -c "UPDATE repo_config SET skip_private_inputs_check_for_collaborators = false WHERE skip_private_inputs_check_for_collaborators;"
```

- [ ] **Step 3: Re-grant intentional exemptions** via `<garnixDomain>/garnix-admin` → Per-repo config (or `DB.upsertRepoConfig`) for any repo that legitimately needs a public repo → private input. Verify a build of such a repo still evaluates; a non-exempt public-repo-with-private-inputs now fails eval with "Public repository has private dependencies…" (expected).

---

## Task 19: Recycle guests (cutover for tap isolation, guest firewall, terminal CA)

Existing guests predate `type = "tap"`/isolation, the guest firewall, and the terminal-CA trust; after deploy the backend signs terminal certs with the dedicated CA, so old guests' web terminals break until recreated.

- [ ] **Step 1: Recycle the pre-warm pool + recreate live guests.** Trigger a redeploy of each live server (push a no-op commit, or use the admin/servers UI to destroy+recreate), and let the pool cycle. For stragglers you don't want to redeploy yet, temporarily isolate their old taps: `ssh erdtree 'for t in $(bridge link show master garnixbr0 | awk -F: "/tap|gx/{print \$2}"); do sudo bridge link set dev $t isolated on; done'` (best-effort; new guests get `gx<id>` taps isolated automatically).

- [ ] **Step 2: Confirm a freshly created guest is on a `type=tap` isolated port** (see Task 20).

---

## Task 20: Runtime verification checklist

Run each check on erdtree after deploy + guest recreation. Record actual output.

- [ ] **C1a/M8 — tap isolation:** `ssh erdtree 'bridge -d link show master garnixbr0'` → every `gx<N>` shows `isolated on`. From guest A: `ping -c2 10.111.0.<B>` → 100% loss even with `sudo sysctl net.bridge.bridge-nf-call-iptables=0` set live; `ping -c2 10.111.0.1` and `curl https://<garnixDomain>/api/...` still work.
- [ ] **C1b/M6/M8 — sysctls:** `ssh erdtree 'sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_local_port_range net.ipv6.conf.garnixbr0.accept_ra'` → `1`, `1`, `42000 60999`, `0`.
- [ ] **C1c — guest firewall:** from erdtree, `nc -zv -w2 10.111.0.<N> 22` succeeds; `nc -zv -w2 10.111.0.<N> 5999` times out; the deployed app still serves via Traefik.
- [ ] **H5 — egress ACL:** `ssh erdtree 'iptables -S FORWARD | head -3'` → rule 1 bridge↔bridge DROP, rule 2 `-i garnixbr0 -j garnix-guest-egress`; `iptables -S garnix-guest-egress` shows conntrack ACCEPT + DROPs + RETURN. From a guest: `curl -m3 http://192.168.1.1` and `nc -zv -w3 147.224.12.5 22` time out; `curl -m5 https://example.com` and the stats POST succeed. From a LAN host, an exposed DNAT SSH port still works.
- [ ] **M7 — DNAT:** expose two guests; `ssh erdtree 'iptables -t nat -S PREROUTING | grep 2200'` → exactly one DNAT per host port; re-expose one → same port, still one rule.
- [ ] **H3 — terminal CA:** on a fresh guest `cat /etc/ssh/garnix-hosting-ca.pub` equals `ssh-keygen -y -f /run/secrets/garnix_terminal_ca` (NOT the hosting pubkey). Open the web terminal → works. Negative: `ssh -i <terminal-ca-private> root@<guest>` → Permission denied; `ssh -i <hosting-key> root@<guest>` still works (deploy identity intact).
- [ ] **H1/H2 — terminal authz:** open the web terminal for a server you own → works; `?user=root` → 400; a non-declared user → 400. (Cross-repo access denial is exercised by the hspec test in Task 2.)
- [ ] **M2 — fluent-bit:** `ssh erdtree 'ls -l /run/secrets/opensearch-garnix'` → `garnix garnix-opensearch`; `systemctl status fluent-bit` healthy; build-log pages populate; `journalctl -u garnixServer` has no opensearch auth errors. Confirm fluent-bit is no longer in `garnix`: `getent group garnix` doesn't list it.
- [ ] **M3 — proxy marker:** `ssh erdtree 'sudo -u caddy cat /run/secrets/garnix_proxy_shared_secret'` succeeds; browser session still reaches the app; `journalctl -u caddy` has no `placeholder: failed to read file`. Negative: `ssh erdtree "curl -s -o /dev/null -w '%{http_code}' -H 'X-Auth-Request-User: x' -H 'X-Auth-Request-Groups: garnix-admins' http://127.0.0.1:8321/api/login/cb"` → 403 (no marker).
- [ ] **JWT TTL:** log in, inspect the `JWT-Cookie` — `Max-Age=1800` and the JWT `exp` ≈ now+1800.
- [ ] **remote-builder key:** `ssh erdtree 'ls -l /run/secrets/garnix_server_remote_builder_ssh'` → `-r--------`; an aarch64 build still farms out.
- [ ] **stats source gate:** confirm a real guest stats POST reaches Caddy as `10.111.0.x` (Caddy access log / tcpdump). If the app domain is CDN-proxied, guests arrive as edge IPs and the check rejects them — fix guest-side (point `statsReportUrl` host at the bridge gateway); confirm grey-cloud instead.
- [ ] **M1 — repo key RAM-only:** on a fresh guest `grep ' /var/garnix/keys ' /proc/mounts` → `tmpfs …mode=755,size=4096k`; after deploy `ls -l /var/garnix/keys/repo-key` → `-r-------- root root` and `head -c 14` → `AGE-SECRET-KEY`. **At-rest proof:** on the host `grep -ac 'AGE-SECRET-KEY' /var/lib/microvms/garnix-<N>/root.img` → `0` (recreated guests; old ones match until recreated). **Must-not-break:** an authentik-gated config still completes OIDC login (`systemctl status garnix-authentik-secrets oauth2-proxy` active); a persistent-server redeploy log shows the new "Copying repo key" step and the service stays up.

---

## Task 21: Authentik enrollment verification (the entitlement is the sole gate)

Because `insecure-oidc-allow-unverified-email = true` + `email.domains = ["*"]`, access rests entirely on Authentik. Confirm (admin UI + API):

- [ ] **No enrollment reachable:** Flows → no Enrollment-designation flow bound to a brand or the login flow; System → Brands → serving brand → **Enrollment flow** empty; the identification stage's Enrollment-flow field empty; no live invitation tokens.
- [ ] **Entitlements never default-granted:** Applications → garnix → Application entitlements = exactly `garnixadmin` + `garnixuser`; each entitlement's bindings target explicit, intentionally-membered groups/users (no all-users group, no catch-all policy); each bound group's membership = owner + intended friends, not a default/auto-join group.
- [ ] **Claim from entitlements only:** the scope mapping providing the `groups` claim derives from `request.user.app_entitlements(...)`, not raw `ak_groups`.
- [ ] **Provider hygiene:** garnix OIDC provider's auth flow has no enrollment stages; redirect URI = exactly `https://<garnixDomain>/oauth2/callback`.
- [ ] **oauth2-proxy match:** in `~/dotfiles-secrets/garnix.nix`, `authentik.allowedGroups == [ "garnix-admins" "garnix-users" ]`, `authentik.adminGroup == "garnix-admins"`.
- [ ] **API spot-check** (uses `authentik-api-token.age`): enrollment flows empty; brand `flow_enrollment == null`; app entitlements = the two expected; each entitlement's policy bindings target only intended groups.
- [ ] **End-to-end negative:** a throwaway Authentik user with no entitlement → oauth2-proxy 403 at `https://<garnixDomain>`. Delete the user.

---

## Task 22: Update the `using-garnix-ci` skill

The hardening changes two documented operator behaviors — record them so the runbook stays correct.

- [ ] **Step 1: Admin curl trick now needs the marker.** The "forge `X-Auth-Request-*` against `127.0.0.1:8321`" admin trick now additionally requires `-H "X-Garnix-Proxy-Auth: $(sudo cat /run/secrets/garnix_proxy_shared_secret)"`. Update the skill's manual-re-trigger / admin section.
- [ ] **Step 2: Guest contract.** Document `garnix.guest.terminalCaPublicKey` (defaults to `sshPublicKey`; the provisioner injects the real terminal-CA pubkey) and that guests must be recreated after the H3 cutover for the web terminal to work.
- [ ] **Step 3: Branch note.** Correct the stale "branch `self-hosting`" reference to `main` on `garnix-ci-selfhosted`.
- [ ] **Step 4: Egress/isolation note.** Record that guests are L2-isolated (bridge port isolation), firewalled, IPv4-only, and blocked from RFC1918/LAN/the remote builder — so a deployed workload cannot reach the host LAN.

---

# Appendix: Finding → Task coverage (self-review)

| Finding | Task(s) |
|---|---|
| C1 (guest↔guest isolation) | 8 (tap hook + sysctl pin), 9 (`type=tap`), 10 (firewall + RA) |
| H1 (terminal repo-access gate) | 2 |
| H2 (cert scoping / no-root / source-address) | 2 (backend), 7 (source-addr option), 14 (aspect); guest-side principal pinning **deferred/not-wired** (documented in Task 2/10 — sshd's login-user principal match keeps it working) |
| H3 (dedicated terminal CA) | 2 (sign), 8 (derive), 9 (inject), 10 (trust), 12/13/14 (secret + wiring) |
| H5 (guest egress ACL) | 8 (chain + option), 15 (blocklist incl. remote builder) |
| M1 (repo-key at rest) | 6 (redeploy re-copy), 10 (tmpfs) |
| M2 (fluent-bit group) | 13 |
| M3 (proxy-provenance marker) | 1 (Env), 5 (backend), 7 (option), 14 (Caddy inject + secret) |
| M4 (private-input collaborator gate) | 3 (backend), 18 (DB cleanup) |
| M5 (on-demand-check cache) | 4 |
| M6 (ephemeral port range) | 8 |
| M7 (DNAT free-list) | 9, 11 (tests) |
| M8 (L2 spoofing) | 8 (accept_ra, port isolation), 10 (IPv4-only) |
| low: remote-builder key 0400 | 13 |
| low: JWT TTL (was no-expiry) | 5 |
| low: stats spoofing | 4 (backend source gate), 14 (Caddy `@stats` remote_ip) |
| low: forge-aware deployer keys | 6 |
| low: fixed CPU model | 8/9 (plumbing), 15 (opt-in) |
| low: L7 rate-limiting | 16 (optional, plugin) |
| low: Authentik enrollment | 21 |
| **Out of scope (trusted-tenant model):** C2, C3, H4, H6 | — |

**Placeholder / consistency notes:** two edit anchors reference existing helpers by role rather than a guessed exact name — the terminal-spec `createSimpleServer` (any owned-public-server helper the spec already exposes) and provisionerd's `_exposure_path` (whatever `write_exposure`/`remove_exposure` already use to locate a guest's JSON). Both are real existing symbols the executor confirms in-file; every other symbol, Env field (`sshTerminalCaKey`, `sshTerminalSourceAddress`, `proxySharedSecret`, `guestSubnetPrefix`), secret path, env var, header (`X-Garnix-Proxy-Auth`), and option name is fixed verbatim and matches across the backend / provisioner / aspect per the Cross-Component Contract table.

**Deploy-order reminder (repeat, because it's the one way to break prod):** create the 3 agenix secrets and bump `dotfiles-secrets` **before** deploying (M3 + H3 are fail-closed); land the Caddy marker-inject and backend marker-check in the **same** `just build-to-erdtree`; after deploy, run the M4 DB cleanup and **recreate guests** (terminal-CA cutover + tap isolation + guest firewall + M1 tmpfs all require fresh guests).

---

Plan complete and saved to `docs/plans/2026-07-20-garnix-hosting-hardening.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints for review.

Which approach?
