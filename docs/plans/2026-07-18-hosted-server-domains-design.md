# Custom & Vanity Domains for Hosted Servers — Design

**Status:** approved design → implementation plan (writing-plans)
**Date:** 2026-07-18
**Repos:** garnix-ci (backend + frontend + nix), dotfiles (erdtree wiring), dotfiles-secrets (domain list)

## Goal

Let garnix-hosted servers answer on **vanity subdomains** and **full custom
domains**, declared in `garnix.yaml` and/or registered by the operator in the
Configure page, with a servers-page **(i)** help modal that shows the exact DNS
records to set for each domain.

## Model

A **hosting base** is a domain under which garnix wildcard-hosts servers
(`<sub>.<base>` "just works" because `*.<base>` DNS → erdtree and Caddy
on-demand TLS issues the cert). A **bare custom domain** is a single FQDN pointed
directly at erdtree. Bases come from three sources:

1. **Default base** — `apps.garnix.example.com` (existing `hostingDomain`).
2. **Operator wildcards** — nix-configured list (`example.dev`, `example.app`,
   `example.net`, `example.link`, `example.help`).
3. **Connected domains** — admin-registered at runtime and DNS-verified.

Every hosted server may declare extra hostnames (`domains:` in `garnix.yaml`).
The backend classifies each declared FQDN:

- **under a known base** → wildcard-covered; no per-server DNS action.
- **not under any base** → bare custom domain; user must add an A/CNAME record.

Both cases get an explicit Traefik `Host(<fqdn>)` router → the guest IP, and the
FQDN is added to the `on-demand-check` allow-list so Caddy issues its cert.

## Approach & rationale

**Declared/explicit routing**, NOT porting upstream's CNAME machinery.

Upstream `hosting-gateway` supports "CNAME your domain, zero garnix-side config"
via a Node on-demand-resolver (CNAME lookup) + Traefik `hostResolver`
(cnameFlattening) + a hardcoded-`garnix.me` fix. That exists to route domains
garnix does **not** know ahead of time. Here every domain is declared (yaml or
registry), so garnix always knows the FQDN and can emit an explicit router +
on-demand allow-entry — reusing the exact `isPrimary` code path. This needs **no
new services on erdtree** and no Caddy/Traefik topology change (the catch-all
`https://` site + `on_demand_tls` already cover any SNI the allow-list approves).

Trade-off accepted: a domain must be declared (yaml or Configure) rather than
auto-discovered by CNAME. That is the intended UX.

## Global constraints (carry into every task)

- **No secrets in public repos.** The five operator domains go in
  `dotfiles-secrets` (private) and are imported into erdtree config. Never commit
  them to the public garnix-ci fork.
- **Merge preserves history (no squash).** Fork commits directly to `main`.
- **Deploys are user-gated.** Do NOT run `just build-to-erdtree`; the operator
  deploys. Migrations apply on deploy.
- **postgresql-typed compile gate.** `[pgSQL|…|]` type-checks against a live md5
  pg at compile time. Any new table/column must be migrated into the dev pg
  (`/tmp/garnix-specs.*/pg-tmp/test`, `TPG_*` env, md5) **before** the backend
  compiles.
- **`-Wall -Werror -Wincomplete-patterns`**, hlint "No hints", golden config
  schema (`backend/.golden/ConfigSchemaSpec/…`) must be regenerated when the
  yaml schema changes.
- **Frontend gates:** `tsc --noEmit`, `next lint`, `knip` all clean.

## Verification style (decided)

**DNS-points-here check.** To verify/activate a connected domain, the backend
does an A/wildcard DNS lookup and confirms it resolves to erdtree's hosting IP.
No TXT token / ownership challenge. This doubles as the (i)-modal "is it live
yet?" status. Requires a DNS-lookup capability in the backend (new dependency —
the `dns` package, or shelling to `getAddrInfo`/`dig`; pick during
implementation, prefer a pure-Haskell `dns` resolver over shelling out).

---

## Component 1 — `garnix.yaml` per-server `domains`

**Files:** `backend/src/Garnix/YamlConfig.hs` (`ServerSection`, ~L275-321);
golden schema `backend/.golden/ConfigSchemaSpec/garnix-config-schema.json`.

- Add `_serverSectionDomains :: [Text]` to `ServerSection` via
  `optionalFieldWithDefault "domains" []` (autodocodec `HasCodec`), with a
  description covering vanity + custom + the "declare it here" requirement.
- Regenerate the golden schema (`cp actual golden` after the ConfigSchemaSpec
  run).

```yaml
servers:
  - configuration: myServer
    deployment: { type: on-branch, branch: main }
    domains:
      - myapp.example.dev      # vanity under an operator wildcard base
      - app.example.com      # bare custom domain (A record)
```

## Component 2 — Operator wildcard bases (nix plumbing)

**Files:** `dotfiles-secrets/domains.nix`; garnix-ci
`backend/nixos-module.nix` (option + env, mirror `hostingDomain` L119-128,
L505-507); `backend/src/Garnix.hs` (read+split env, ~L274, L402);
`backend/src/Garnix/Monad.hs` (Env field, ~L86); dotfiles
`modules/hosts/erdtree/garnix.nix` (set the option);
`backend/test/spec/Garnix/TestHelpers/Monad.hs` (Env default, L315).

- `dotfiles-secrets/domains.nix`:
  `garnixExtraHostingDomains = [ "example.dev" "example.app" "example.net" "example.link" "example.help" ];`
- New option `services.garnixServer.extraHostingDomains` (`listOf str`, default
  `[]`) → env `GARNIX_EXTRA_HOSTING_DOMAINS` (comma-joined via
  `lib.concatStringsSep ","`).
- `Garnix.hs`: read env, split on `,`, drop blanks → `Env.extraHostingDomains :: [Text]`.
- erdtree `garnix.nix`: `extraHostingDomains = domains.garnixExtraHostingDomains;`
- **Operator DNS (manual, doc only):** wildcard `*.<domain>` → erdtree per base.
  No Caddy/Traefik change.

## Component 3 — Backend routing / TLS / persistence

**Files:** `backend/src/Garnix/API/Hosts.hs` (`ToJSON HostList` L86-159,
`getDomainsForOnDemandResolver` L254-270); `backend/src/Garnix/Hosting/Deploy.hs`
(`ServerToSpinUp`, `getDeployPlan` L119-147, execute path); `backend/src/Garnix/Types.hs`
(`Host` record ~L1690, FQDN builders); `backend/src/Garnix/DB.hs`
(server row read/write, exposures); migration `add-server-domains`.

- **Migration `add-server-domains`:** `ALTER TABLE servers ADD COLUMN IF NOT
  EXISTS domains jsonb NOT NULL DEFAULT '[]'` (list of declared FQDNs for the
  deployed server). Apply to dev pg before compiling.
- **Deploy threading:** `ServerSection.domains` → validated → written to
  `servers.domains` when a server spins up.
- **Validation helper** (new, e.g. `Garnix/Hosting/Domains.hs` or in Deploy):
  for each declared FQDN, classify as under-a-known-base
  (`hostingDomain` ++ `extraHostingDomains` ++ verified connected) or bare
  custom; reject an FQDN already claimed by another live server. Known-base list
  is assembled from Env + a DB read of verified connected domains.
- **`getDomainsForOnDemandResolver`:** append every running server's declared
  domains (full FQDNs, un-suffixed) so Caddy issues certs.
- **`ToJSON HostList` routers:** add a full-FQDN router variant — `routerMapPair`
  currently appends `"." <> domain`; add a sibling that uses the FQDN verbatim as
  the `Host(...)` rule and points the service at the guest IP. Emit one per
  declared domain. `isPrimary` (L106) is the structural template.

## Component 4 — Connected-domains registry (Configure, admin-only)

**Files:** migration `add-connected-domains`; `backend/src/Garnix/DB.hs` (CRUD);
`backend/src/Garnix/API/Configure.hs` (routes+DTOs+handlers, gated by
`requireSelfHostConfig`); a DNS-resolve helper (new dep); frontend
`frontend/src/app/configure/page.tsx` (new section) +
`frontend/src/services/configure.ts`.

- **Migration `add-connected-domains`:**
  ```sql
  CREATE TABLE connected_domains (
    id           bigserial PRIMARY KEY,
    domain       character varying NOT NULL UNIQUE,
    is_wildcard  boolean NOT NULL DEFAULT true,
    verified_at  timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now()
  );
  ```
  (No `verification_token` — the DNS-points-here check needs none.)
- **DB.hs:** `getConnectedDomains`, `getVerifiedConnectedDomains`,
  `addConnectedDomain`, `deleteConnectedDomain`, `markConnectedDomainVerified`.
- **Configure API** under `/api/configure/domains`: `GET` list, `POST` add,
  `POST /<id>/verify` (runs the DNS check, sets `verified_at`), `DELETE /<id>`.
  DTOs follow the `RepoTimeoutDto` boilerplate (underscore lens fields +
  `ourToJSON`/`ourParseJSON`); all handlers call `requireSelfHostConfig auth`.
- **Verify handler:** resolve the domain's A record (and/or a probe subdomain for
  a wildcard base), compare to erdtree's hosting IP (Component 5 config); on
  match set `verified_at = now()`.
- **Frontend:** a "Connected domains" section in `app/configure/page.tsx`
  (add-row + per-domain status/verify/delete), mirroring `ArtifactSettings` /
  `BuildTimeoutSettings`; `services/configure.ts` gets the CRUD wrappers.
- Verified connected domains join the known-base list used in Component 3.

## Component 5 — Servers-page (i) help modal

**Files:** `frontend/src/app/servers/page.tsx` (+ styles) — add an **(i)** button
by the SSH/copy controls; a new `frontend/src/app/servers/…/domainsModal`
component; backend exposes the hosting IP + each server's domains.

- `RunningServer` already carries the server's URL; extend the servers endpoint
  (or reuse `_runningServerExposed`/a new field) to include the declared
  `domains` and their classification (wildcard-covered vs bare-custom) + the
  hosting public IP + the default base (as CNAME target).
- **Config:** new `services.garnixServer.hostingPublicIp` option →
  `GARNIX_HOSTING_PUBLIC_IP` → Env; used to render A-record instructions. If
  unset, the modal shows only the CNAME-to-a-garnix-domain instruction (works for
  subdomains; apex domains then need the operator to supply the IP).
- **Modal:** dropdown of the server's domains; per domain: *wildcard-covered* →
  "no DNS needed"; *bare custom* → `A  <domain>  →  <hostingPublicIp>` (or
  `CNAME  <sub>  →  <default base FQDN>`); plus a live "resolves here / not yet"
  status via the same check as Component 4.

## Component 6 — Cross-cutting

- Golden config-schema regenerated (Component 1).
- `TestHelpers/Monad.hs` Env default for `extraHostingDomains` (and any new Env
  fields) populated.
- Each migration applied to the dev pg before the backend compiles.
- Backend `-Wall -Werror` + hlint; frontend `tsc`/`lint`/`knip` gates.
- **README** (garnix-ci): document the `garnix.yaml` `domains:` field (vanity +
  custom), the operator `extraHostingDomains` + wildcard-DNS setup, the
  Configure "connected domains" flow, and the (i)-modal DNS records.
- **dotfiles**: bump the garnix-ci input; the operator sets wildcard DNS + deploys.

## Out of scope (explicit)

- Upstream CNAME auto-discovery (Node resolver / Traefik hostResolver).
- TXT ownership challenges (chose DNS-points-here).
- Automated DNS record creation (Cloudflare API) — records are set manually.
- Per-repo (non-admin) domain registration — the Configure registry is
  admin-only, matching the existing `requireSelfHostConfig` gate.
