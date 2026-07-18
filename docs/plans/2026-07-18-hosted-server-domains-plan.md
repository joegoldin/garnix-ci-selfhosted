# Custom & Vanity Domains for Hosted Servers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let garnix-hosted servers answer on vanity subdomains and full custom domains — declared per-server in `garnix.yaml` and/or registered by the operator in the Configure page — with a servers-page **(i)** modal that shows the exact DNS records to set.

**Architecture:** Declared-domain routing. Every domain is known ahead of time (from `garnix.yaml` or the admin registry), so the backend emits an explicit Traefik `Host(<fqdn>)` router → guest IP and adds the FQDN to the Caddy `on-demand-check` allow-list — reusing the existing `isPrimary` path. No upstream CNAME-resolver / Traefik `hostResolver` / new erdtree services. Verification of connected domains is a DNS-points-here A/wildcard lookup.

**Tech Stack:** Haskell/Servant backend (`postgresql-typed` compile-time SQL, autodocodec yaml schema), sqitch migrations (deploy-only), Next.js/zod frontend, NixOS modules, central Caddy(on-demand TLS)+Traefik on erdtree.

## Global Constraints

- No secrets in public repos — the five operator domains live in `dotfiles-secrets` (private), never in the garnix-ci fork.
- Fork commits directly to `main`; merges preserve history (no squash).
- Deploys are user-gated — never run `just build-to-erdtree`; migrations apply on the operator's deploy.
- `postgresql-typed` type-checks `[pgSQL|…|]` against a live md5 pg at compile time: apply each new migration to the dev pg **before** compiling the backend. Compile gate: `nix develop -c bash -c 'export TPG_HOST=<specsdir>/pg-tmp/test TPG_SOCK=<specsdir>/pg-tmp/test/.s.PGSQL.9178 TPG_PORT=9178 TPG_USER=garnix TPG_PASS=garnix TPG_DB=garnix PGPASSWORD=garnix; cd backend && cabal build lib:garnix'`.
- Backend: `-Wall -Werror -Wincomplete-patterns`, hlint "No hints". Golden config schema (`backend/.golden/ConfigSchemaSpec/garnix-config-schema.json`) regenerated whenever the yaml schema changes (`cp actual golden`).
- Frontend gates: `tsc --noEmit`, `next lint`, `knip` all clean (run the tools against the store node_modules; symlink the `frontend_ageWasm_default` artifact into `frontend/src/age-wasm-compiled` first).
- Domains in `garnix.yaml` and the registry are **full FQDNs**.
- Every new `Env` field must be populated in `backend/test/spec/Garnix/TestHelpers/Monad.hs` (Env constructor ~L303).

## File Structure

- `backend/src/Garnix/YamlConfig.hs` — add `domains` to `ServerSection` (schema).
- `backend/src/Garnix/Monad.hs` — Env fields `extraHostingDomains :: [Text]`, `hostingPublicIp :: Maybe Text`.
- `backend/src/Garnix.hs` — read/split the two new env vars.
- `backend/nixos-module.nix` — options `extraHostingDomains`, `hostingPublicIp` + env lines.
- `backend/src/Garnix/Types.hs` — `Host._hostDomains :: [Text]`.
- `backend/src/Garnix/DB.hs` — `servers.domains` column threading; `connected_domains` CRUD.
- `backend/src/Garnix/Hosting/Domains.hs` — **new**: known-base classifier + FQDN validation.
- `backend/src/Garnix/Hosting/Deploy.hs` — thread `domains` from `ServerSection` → validate → `servers` row.
- `backend/src/Garnix/API/Hosts.hs` — on-demand allow-list + explicit FQDN routers; expose server domains + hosting IP in the servers DTO.
- `backend/src/Garnix/Dns.hs` — **new**: `resolvesToHostingIp :: Text -> M Bool` (DNS A/wildcard lookup).
- `backend/src/Garnix/API/Configure.hs` — connected-domains CRUD + verify.
- `sql/deploy/add-server-domains.sql`, `sql/deploy/add-connected-domains.sql` + `sql/sqitch.plan`.
- `frontend/src/services/configure.ts`, `frontend/src/services/servers.ts` — CRUD + domain DTO.
- `frontend/src/app/configure/page.tsx` — "Connected domains" section.
- `frontend/src/app/servers/page.tsx` + `frontend/src/app/servers/domainsModal/` — the (i) modal.
- Docs: `README.md`, `/home/joe/Development/agent-skills/skills/using-garnix-ci/SKILL.md`, dotfiles `modules/hosts/erdtree/garnix.nix`, `dotfiles-secrets/domains.nix`, dotfiles `flake.lock`.

---

### Task 1: `garnix.yaml` per-server `domains` field

**Files:**
- Modify: `backend/src/Garnix/YamlConfig.hs` (`ServerSection` record ~L275-283; `HasCodec` ~L286-321)
- Modify (golden): `backend/.golden/ConfigSchemaSpec/garnix-config-schema.json`
- Test: `backend/test/spec/Garnix/ConfigSchemaSpec.hs` (existing golden spec)

**Interfaces:**
- Produces: `_serverSectionDomains :: ServerSection -> [Text]` (default `[]`), accessed as `s ^. domains` via the generated lens.

- [ ] **Step 1: Add the record field.** In `ServerSection` add `_serverSectionDomains :: [Text]` after `_serverSectionPorts`.

- [ ] **Step 2: Add the codec field.** After the `ports` `optionalFieldWithDefault` (ending `.= _serverSectionPorts`), append:
```haskell
      <*> optionalFieldWithDefault
        "domains"
        []
        "Extra hostnames this server should also answer on (full FQDNs). A name under a configured base domain (the default apps domain or an operator/connected base) is wildcard-covered — no DNS action. Any other name is a bare custom domain and needs an A/CNAME record pointing at the garnix host (see the Servers page (i) menu). Each must be declared here (or in the Configure page) to be routed and get a cert."
      .= _serverSectionDomains
```

- [ ] **Step 3: Run the golden spec to see it fail.** `nix develop -c bash -c '<TPG env>; cd backend && cabal test spec --test-options="--match ConfigSchema"'` — Expected: FAIL, golden ≠ actual (new `domains` property).

- [ ] **Step 4: Accept the golden.** `cp backend/.golden/ConfigSchemaSpec/garnix-config-schema.json/actual backend/.golden/ConfigSchemaSpec/garnix-config-schema.json/golden` (verify the diff is only the new `domains` field).

- [ ] **Step 5: Compile clean.** Run the lib compile gate — Expected: `Exit 0`.

- [ ] **Step 6: Commit.** `git commit -am "feat(yaml): servers[].domains — extra hostnames per hosted server"`

---

### Task 2: Operator wildcard bases + hosting public IP (nix env → Env)

**Files:**
- Modify: `backend/src/Garnix/Monad.hs` (Env record ~L86, near `hostingDomain`)
- Modify: `backend/src/Garnix.hs` (env reads ~L274; Env assignment ~L402)
- Modify: `backend/nixos-module.nix` (options ~L119-128; env list ~L505-507)
- Modify: `backend/test/spec/Garnix/TestHelpers/Monad.hs` (Env constructor ~L303)
- Modify: `dotfiles-secrets/domains.nix`
- Modify: `dotfiles modules/hosts/erdtree/garnix.nix` (services.garnixServer block ~L231-302)

**Interfaces:**
- Produces: `Env.extraHostingDomains :: [Text]`, `Env.hostingPublicIp :: Maybe Text`, accessed `view #extraHostingDomains` / `view #hostingPublicIp`.

- [ ] **Step 1: Env fields.** In `Monad.hs` after `hostingDomain :: Text,` add:
```haskell
    -- | Extra wildcard base domains the operator owns (GARNIX_EXTRA_HOSTING_DOMAINS,
    -- comma-separated). A server domain under any of these is wildcard-routed.
    extraHostingDomains :: [Text],
    -- | Public IP of the garnix host, for A-record instructions in the Servers
    -- (i) menu (GARNIX_HOSTING_PUBLIC_IP). Nothing => show CNAME instructions only.
    hostingPublicIp :: Maybe Text,
```

- [ ] **Step 2: Read the env.** In `Garnix.hs` near the `hostingDomain'` read (~L274) add:
```haskell
  extraHostingDomains' <-
    maybe [] (filter (not . T.null) . T.splitOn "," . cs) <$> lookupEnv "GARNIX_EXTRA_HOSTING_DOMAINS"
  hostingPublicIp' <- fmap cs <$> lookupEnv "GARNIX_HOSTING_PUBLIC_IP"
```
and in the `Env { … }` record assignment add `extraHostingDomains = extraHostingDomains',` and `hostingPublicIp = hostingPublicIp',`.

- [ ] **Step 3: Test Env defaults.** In `TestHelpers/Monad.hs` Env constructor add `extraHostingDomains = [],` and `hostingPublicIp = Nothing,`.

- [ ] **Step 4: nixos-module option + env.** In `backend/nixos-module.nix` after the `hostingDomain` option add:
```nix
        extraHostingDomains = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "example.dev" ];
          description = "Extra wildcard base domains the operator owns; servers can be hosted at <name>.<domain>. Each needs a manual wildcard *.<domain> -> host DNS record. Sets GARNIX_EXTRA_HOSTING_DOMAINS.";
        };
        hostingPublicIp = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "203.0.113.10";
          description = "Public IP of the garnix host, shown in A-record instructions for bare custom domains. Sets GARNIX_HOSTING_PUBLIC_IP.";
        };
```
and in the `Environment` list (after the `GARNIX_HOSTING_DOMAIN` optional block) add:
```nix
        ++ lib.optionals (config.services.garnixServer.extraHostingDomains != [ ]) [
          "GARNIX_EXTRA_HOSTING_DOMAINS=${lib.concatStringsSep "," config.services.garnixServer.extraHostingDomains}"
        ]
        ++ lib.optionals (config.services.garnixServer.hostingPublicIp != null) [
          "GARNIX_HOSTING_PUBLIC_IP=${config.services.garnixServer.hostingPublicIp}"
        ]
```

- [ ] **Step 5: dotfiles-secrets.** In `dotfiles-secrets/domains.nix` add before the closing `}`:
```nix
  # garnix hosting — extra wildcard base domains for hosted servers. Each needs a
  # manual wildcard *.<domain> -> erdtree DNS record (grey cloud). Caddy on-demand
  # + the backend handle certs + routing.
  garnixExtraHostingDomains = [ "example.dev" "example.app" "example.net" "example.link" "example.help" "example.garden" "example.click" ];
```

- [ ] **Step 6: erdtree wiring.** In dotfiles `garnix.nix` `services.garnixServer` block add:
```nix
        extraHostingDomains = domains.garnixExtraHostingDomains;
        hostingPublicIp = domains.garnixHostingPublicIp;   # from dotfiles-secrets (host IP is secret)
```

- [ ] **Step 7: Compile + eval.** Backend lib compile gate → `Exit 0`. `nix eval .#nixosConfigurations.erdtree.config.system.build.toplevel.drvPath` (from dotfiles, after bumping input in Task 12) — defer eval to Task 12; here just confirm the backend compiles.

- [ ] **Step 8: Commit** (garnix-ci): `git commit -am "feat(hosting): extraHostingDomains + hostingPublicIp config"`. dotfiles + dotfiles-secrets committed in Task 12.

---

### Task 3: `servers.domains` column + `Host._hostDomains`

**Files:**
- Create: `sql/deploy/add-server-domains.sql`
- Modify: `sql/sqitch.plan`
- Modify: `backend/src/Garnix/Types.hs` (`Host` record ~L1690-1704)
- Modify: `backend/src/Garnix/DB.hs` (server INSERT ~L1742-1755; every host SELECT that lists `is_primary`: L1781, L1854, L1882, L1993, L2017; `getAllRunningHosts` L1865)

**Interfaces:**
- Produces: `Host._hostDomains :: [Text]` (lens `domains`); `servers.domains jsonb` persisted per server.

- [ ] **Step 1: Migration.** Create `sql/deploy/add-server-domains.sql`:
```sql
-- Deploy garnix:add-server-domains to pg
-- Extra declared hostnames a deployed server answers on (vanity/custom domains).
BEGIN;
ALTER TABLE servers ADD COLUMN IF NOT EXISTS domains jsonb NOT NULL DEFAULT '[]'::jsonb;
COMMIT;
```

- [ ] **Step 2: sqitch.plan.** Append: `add-server-domains 2026-07-18T10:00:00Z joegoldin <joe@joegold.in> # servers.domains: extra declared hostnames per hosted server`

- [ ] **Step 3: Apply to dev pg.** `nix develop -c bash -c '<TPG env>; psql -h <specsdir>/pg-tmp/test -p 9178 -U garnix -d garnix -c "ALTER TABLE servers ADD COLUMN IF NOT EXISTS domains jsonb NOT NULL DEFAULT '"'"'[]'"'"'::jsonb;"'` (so the new `[pgSQL|…|]` queries type-check).

- [ ] **Step 4: Host field.** In `Types.hs` `Host` add `_hostDomains :: [Text],` after `_hostIsPrimary :: Bool`. (A jsonb text[] read as `[Text]` — use the same decode as other jsonb list columns; if none, add `import Data.Aeson (eitherDecode)` handling in DB. Simpler: store as `jsonb` and read with the postgresql-typed `jsonb` → `Aeson.Value`, then `^.. values . _String`. Mirror how `servers.exposed` jsonb is read in `getServerExposures`.)

- [ ] **Step 5: Thread the column.** In `DB.hs`: add `, domains` to the `INSERT INTO servers` column list (L1742-1752) with the bound value `${domainsJson}` where `domainsJson :: Aeson.Value = toJSON domainList`; add `servers.domains` to each host-select column list (L1781, L1854, L1882, L1993, L2017); in `getAllRunningHosts` (L1865) decode it into `_hostDomains`. Use `servers.exposed`'s jsonb handling as the exact template.

- [ ] **Step 6: Compile clean** (after Step 3). Lib compile gate → `Exit 0`.

- [ ] **Step 7: Commit.** `git commit -am "feat(hosting): servers.domains column + Host._hostDomains"`

---

### Task 4: Domain validation + deploy threading

**Files:**
- Create: `backend/src/Garnix/Hosting/Domains.hs`
- Modify: `backend/garnix.cabal` (expose the new module)
- Modify: `backend/src/Garnix/Hosting/Deploy.hs` (`ServerToSpinUp` + `getDeployPlan` L119-147; the spin-up write path)
- Modify: `backend/src/Garnix/DB.hs` (`getVerifiedConnectedDomains` — from Task 6; if implementing Task 4 first, stub it to `pure []` and wire in Task 6)

**Interfaces:**
- Consumes: `Env.extraHostingDomains`, `Env.hostingDomain`, `DB.getVerifiedConnectedDomains :: M [Text]`.
- Produces: `knownBaseDomains :: M [Text]`; `classifyDomain :: [Text] -> Text -> DomainKind` where `data DomainKind = WildcardCovered Text | BareCustom` (the `Text` is the matched base); `validateServerDomains :: [Text] -> M ()` (throws on collision with another live server's domains).

- [ ] **Step 1: Module.** Create `Hosting/Domains.hs`:
```haskell
module Garnix.Hosting.Domains
  ( DomainKind (..), knownBaseDomains, classifyDomain, validateServerDomains )
where

import Garnix.DB qualified as DB
import Garnix.Monad
import Garnix.Prelude
import Data.Text qualified as T

data DomainKind = WildcardCovered Text | BareCustom
  deriving stock (Eq, Show)

knownBaseDomains :: M [Text]
knownBaseDomains = do
  base <- view #hostingDomain
  extra <- view #extraHostingDomains
  connected <- DB.getVerifiedConnectedDomains
  pure (base : extra <> connected)

-- | A domain is wildcard-covered if it is a strict subdomain of a known base.
classifyDomain :: [Text] -> Text -> DomainKind
classifyDomain bases fqdn =
  case filter (\b -> ("." <> b) `T.isSuffixOf` fqdn && fqdn /= b) bases of
    (b : _) -> WildcardCovered b
    [] -> BareCustom

validateServerDomains :: [Text] -> M ()
validateServerDomains declared = do
  taken <- DB.getAllDeclaredServerDomains
  let clashes = filter (`elem` taken) declared
  unless (null clashes)
    $ throw (OtherError $ "Domain(s) already in use by another server: " <> T.intercalate ", " clashes)
```
Add `DB.getAllDeclaredServerDomains :: M [Text]` (SELECT + flatten `servers.domains` of live servers) mirroring `getServerExposures`.

- [ ] **Step 2: cabal.** Add `Garnix.Hosting.Domains` to `exposed-modules` in `backend/garnix.cabal` (alongside other `Garnix.Hosting.*`).

- [ ] **Step 3: ServerToSpinUp.** Add a `domains :: [Text]` field to `ServerToSpinUp` (in `Deploy.hs`); in `getDeployPlan` (L134-145) set `domains = s ^. YamlConfig.domains` from the section.

- [ ] **Step 4: Validate + persist.** In `getDeployPlan`, before returning the plan, call `validateServerDomains (concatMap domains toSpinUp)`; in the spin-up write path pass `domains` to the `INSERT INTO servers` (Task 3 Step 5) value.

- [ ] **Step 5: Compile clean.** Lib compile gate → `Exit 0` (with Task 6's `getVerifiedConnectedDomains` stubbed to `pure []` if Task 6 not yet done).

- [ ] **Step 6: Commit.** `git commit -am "feat(hosting): validate + persist declared server domains"`

---

### Task 5: Explicit routers + on-demand allow-list for declared domains

**Files:**
- Modify: `backend/src/Garnix/API/Hosts.hs` (`ToJSON HostList` L86-159; `getDomainsForOnDemandResolver` L254-270)

**Interfaces:**
- Consumes: `Host._hostDomains`.
- Produces: Traefik routers keyed by the full FQDN → guest IP; on-demand allow-list includes declared FQDNs.

- [ ] **Step 1: Full-FQDN router variant.** In `ToJSON HostList` add, next to `routerMapPair`:
```haskell
        fqdnRouterPair serviceDomain fqdn =
          ( fqdn
          , [aesonQQ| { service: #{serviceDomain},
                        rule: #{"Host(`" <> fqdn <> "`)"},
                        middlewares: ["heartbeatmiddleware"] } |]
          )
```
and in `httpRouters`'s `concatMap` per host append `<> [fqdnRouterPair (hostToDomainName h) d | d <- h ^. domains]`. (The service `hostToDomainName h` already maps to the guest IP in `httpServices`.)

- [ ] **Step 2: on-demand allow-list.** In `getDomainsForOnDemandResolver` per-host `concatMap` append `<> (host ^. domains)` so Caddy issues certs for declared FQDNs.

- [ ] **Step 3: Compile clean.** Lib compile gate → `Exit 0`.

- [ ] **Step 4: Manual verification note.** (No local spec — the Traefik/Caddy path needs a deploy.) Add a `HostsSpec` assertion if one exists that snapshots `/api/hosts/traefik`; otherwise verify the JSON shape by an inline `ghci`/spec that renders `toJSON (HostList …)` for a host with `_hostDomains = ["myapp.example.dev"]` and asserts a `Host(`myapp.example.dev`)` router is present.

- [ ] **Step 5: Commit.** `git commit -am "feat(hosting): emit explicit routers + on-demand certs for declared domains"`

---

### Task 6: `connected_domains` table + DB CRUD

**Files:**
- Create: `sql/deploy/add-connected-domains.sql`; Modify: `sql/sqitch.plan`
- Modify: `backend/src/Garnix/DB.hs`

**Interfaces:**
- Produces: `getConnectedDomains :: M [(Int64, Text, Bool, Maybe UTCTime)]`; `getVerifiedConnectedDomains :: M [Text]`; `addConnectedDomain :: Text -> Bool -> M Int64`; `deleteConnectedDomain :: Int64 -> M ()`; `markConnectedDomainVerified :: Int64 -> M ()`.

- [ ] **Step 1: Migration.** Create `sql/deploy/add-connected-domains.sql`:
```sql
-- Deploy garnix:add-connected-domains to pg
-- Operator-registered base/custom domains for hosting; DNS-points-here verified.
BEGIN;
CREATE TABLE connected_domains (
  id           bigserial PRIMARY KEY,
  domain       character varying NOT NULL UNIQUE,
  is_wildcard  boolean NOT NULL DEFAULT true,
  verified_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);
COMMIT;
```

- [ ] **Step 2: sqitch.plan.** Append: `add-connected-domains 2026-07-18T10:05:00Z joegoldin <joe@joegold.in> # connected_domains: operator-registered hosting domains (DNS-points-here verified)`

- [ ] **Step 3: Apply to dev pg** (paste the `CREATE TABLE` via `psql` as in Task 3 Step 3).

- [ ] **Step 4: DB functions.** Add to `DB.hs` (mirror the timeout upsert / `getReposWithBuildTimeout` patterns):
```haskell
getConnectedDomains :: M [(Int64, Text, Bool, Maybe UTCTime)]
getConnectedDomains = pgQuery [pgSQL|SELECT id, domain, is_wildcard, verified_at FROM connected_domains ORDER BY domain|]

getVerifiedConnectedDomains :: M [Text]
getVerifiedConnectedDomains = pgQuery [pgSQL|SELECT domain FROM connected_domains WHERE verified_at IS NOT NULL|]

addConnectedDomain :: Text -> Bool -> M Int64
addConnectedDomain domain isWildcard =
  fmap head $ pgQuery [pgSQL|INSERT INTO connected_domains (domain, is_wildcard) VALUES (${domain}, ${isWildcard}) RETURNING id|]

deleteConnectedDomain :: Int64 -> M ()
deleteConnectedDomain cid = void $ pgExec [pgSQL|DELETE FROM connected_domains WHERE id = ${cid}|]

markConnectedDomainVerified :: Int64 -> M ()
markConnectedDomainVerified cid = void $ pgExec [pgSQL|UPDATE connected_domains SET verified_at = now() WHERE id = ${cid}|]
```

- [ ] **Step 5: Wire into Task 4.** Replace the `getVerifiedConnectedDomains` stub in `Domains.hs` with the real DB call (already referenced).

- [ ] **Step 6: Compile clean** (after Step 3). → `Exit 0`.

- [ ] **Step 7: Commit.** `git commit -am "feat(hosting): connected_domains table + CRUD"`

---

### Task 7: DNS-points-here resolver

**Files:**
- Create: `backend/src/Garnix/Dns.hs`; Modify: `backend/garnix.cabal` (module + `dns` dep)
- Modify: `backend/nix` package deps if the Haskell env pins its package set (check how deps are provided)

**Interfaces:**
- Consumes: `Env.hostingPublicIp`.
- Produces: `resolvesToHostingIp :: Text -> M Bool` — True iff the domain's A records include the hosting IP (for a wildcard base, probe `garnix-verify.<domain>`).

- [ ] **Step 1: Add the `dns` dependency.** Add `dns` to `build-depends` in `backend/garnix.cabal`; confirm it resolves in the nix Haskell package set (`nix develop -c ghc-pkg list dns`). If unavailable, fall back to shelling `getAddrInfo` via `Network.Socket.getAddrInfo` (no new dep) — prefer this if `dns` isn't already packaged.

- [ ] **Step 2: Module** (getAddrInfo variant, no new dep):
```haskell
module Garnix.Dns (resolvesToHostingIp) where

import Garnix.Monad
import Garnix.Prelude
import Network.Socket (getAddrInfo, defaultHints, AddrInfo (..), SockAddr (..))
import Data.Text qualified as T

-- | True iff @host@ (or, for a wildcard base, a probe label under it) resolves
-- to the configured hosting IP. Best-effort: returns False on lookup failure.
resolvesToHostingIp :: Text -> M Bool
resolvesToHostingIp host = do
  mIp <- view #hostingPublicIp
  case mIp of
    Nothing -> pure False
    Just ip -> liftIO $ (`catchAnyIO` const (pure False)) $ do
      infos <- getAddrInfo (Just defaultHints) (Just (T.unpack host)) Nothing
      pure $ any ((== T.unpack ip) . takeWhile (/= ':') . show . addrAddress) infos
  where
    catchAnyIO = \a h -> a `catch` (h :: SomeException -> IO Bool)
```
(Adjust the IP-compare to strip the port; for IPv4 `SockAddrInet` compare the host part. Refine to compare `hostAddressToTuple` rather than `show` for robustness.)

- [ ] **Step 3: cabal module.** Add `Garnix.Dns` to `exposed-modules`.

- [ ] **Step 4: Compile clean.** → `Exit 0`.

- [ ] **Step 5: Commit.** `git commit -am "feat(hosting): DNS-points-here resolver"`

---

### Task 8: Configure API — connected-domains CRUD + verify

**Files:**
- Modify: `backend/src/Garnix/API/Configure.hs` (route record L34-76; server L96-…; DTOs L99-124; handlers L206-273)

**Interfaces:**
- Consumes: `DB.getConnectedDomains/addConnectedDomain/deleteConnectedDomain/markConnectedDomainVerified`, `Garnix.Dns.resolvesToHostingIp`.
- Produces endpoints under `/api/configure/domains`.

- [ ] **Step 1: Routes.** Add to `ConfigureAPI`:
```haskell
    _configureAPIListDomains :: route :- "domains" :> Get '[JSON] [ConnectedDomainDto],
    _configureAPIAddDomain :: route :- "domains" :> ReqBody '[JSON] AddDomainDto :> Post '[JSON] ConnectedDomainDto,
    _configureAPIVerifyDomain :: route :- "domains" :> Capture "id" Int64 :> "verify" :> Post '[JSON] ConnectedDomainDto,
    _configureAPIDeleteDomain :: route :- "domains" :> Capture "id" Int64 :> Delete '[JSON] NoContent,
```

- [ ] **Step 2: DTOs** (mirror `RepoTimeoutDto` boilerplate):
```haskell
data ConnectedDomainDto = ConnectedDomainDto
  { _connectedDomainDtoId :: Int64,
    _connectedDomainDtoDomain :: Text,
    _connectedDomainDtoIsWildcard :: Bool,
    _connectedDomainDtoVerified :: Bool }
  deriving stock (Eq, Show, Generic)
instance ToJSON ConnectedDomainDto where { toEncoding = ourToEncoding; toJSON = ourToJSON }

newtype AddDomainDto = AddDomainDto { _addDomainDtoDomain :: Text }
  deriving stock (Eq, Show, Generic)
instance FromJSON AddDomainDto where parseJSON = ourParseJSON
```

- [ ] **Step 3: Handlers.** Each begins `requireSelfHostConfig auth`. List → map DB rows to DTO (`verified = isJust verified_at`). Add → `addConnectedDomain d True` then return the DTO (unverified). Verify → look up the domain, `resolvesToHostingIp` (probe `"garnix-verify." <> domain` if wildcard, else the domain); if True `markConnectedDomainVerified id`; return the refreshed DTO. Delete → `deleteConnectedDomain id`, `NoContent`. Wire all four into both the `Authenticated` and unauthenticated `configureAPI` records (unauth → `throw Unauthorized`).

- [ ] **Step 4: Compile clean.** → `Exit 0`.

- [ ] **Step 5: Commit.** `git commit -am "feat(configure): connected-domains CRUD + DNS-points-here verify"`

---

### Task 9: Frontend — Configure "Connected domains" section

**Files:**
- Modify: `frontend/src/services/configure.ts`
- Modify: `frontend/src/app/configure/page.tsx` (mirror `ArtifactSettings` / `BuildTimeoutSettings`)

**Interfaces:**
- Consumes the `/api/configure/domains` endpoints.

- [ ] **Step 1: Services.** Add:
```ts
const connectedDomainSchema = z.object({ id: z.number(), domain: z.string(), is_wildcard: z.boolean(), verified: z.boolean() });
export type ConnectedDomain = z.infer<typeof connectedDomainSchema>;
export const getConnectedDomains = () => fetchFromAPI(z.array(connectedDomainSchema), "GET", "configure/domains");
export const addConnectedDomain = (domain: string) => fetchFromAPI(connectedDomainSchema, "POST", "configure/domains", { body: JSON.stringify({ domain }) });
export const verifyConnectedDomain = (id: number) => fetchFromAPI(connectedDomainSchema, "POST", `configure/domains/${id}/verify`);
export const deleteConnectedDomain = (id: number) => fetchFromAPI(z.any(), "DELETE", `configure/domains/${id}`);
```

- [ ] **Step 2: Section component.** Add a `ConnectedDomainsSettings` component in `app/configure/page.tsx` gated by `selfHostMode`: a `useLoading(getConnectedDomains)` list; each row shows `domain`, a verified badge (green "resolves here" / grey "not yet"), a **Verify** button (`verifyConnectedDomain` then reload), and **Delete**; an add-row (text input + **Add** → `addConnectedDomain` then reload). Reuse the `run()`/`busy`/`reload` pattern from `ArtifactSettings`.

- [ ] **Step 3: Verify frontend gates.** tsc + `next lint` + `knip` clean (store node_modules + age-wasm symlink). Expected: no errors.

- [ ] **Step 4: Commit.** `git commit -am "feat(configure): Connected domains section"`

---

### Task 10: Frontend — Servers-page (i) DNS-help modal

**Files:**
- Modify: `backend/src/Garnix/API/Hosts.hs` (the running-servers DTO — add `domains` + classification + `hosting_public_ip` + `default_base`)
- Modify: `frontend/src/services/servers.ts`
- Modify: `frontend/src/app/servers/page.tsx` (Connect cell ~L129; add the (i) button by `CopyableCommand`)
- Create: `frontend/src/app/servers/domainsModal/index.tsx` + `styles.module.css`

**Interfaces:**
- Consumes: `RunningServer.domains` (declared FQDNs), the hosting IP, the default base.

- [ ] **Step 1: Expose server domains + IP.** In the running-servers endpoint add to each server's JSON: `domains` (the declared list from `_runningServer…`/`servers.domains`), `hosting_public_ip` (`view #hostingPublicIp`), and `default_base` (`view #hostingDomain`). Add `_runningServerDomains :: [Text]` to `RunningServer` (Helpers.hs) fed from `servers.domains`.

- [ ] **Step 2: Services.** In `servers.ts` extend the server schema with `domains: z.array(z.string()).default([])`, and add top-level `hosting_public_ip`/`default_base` to the servers response schema (or a small `getHostingInfo` call). Classify client-side: a domain is wildcard-covered if it ends with `.<default_base>` or `.<one of the operator bases>` — simplest: the backend already knows; add a `covered: boolean` per domain in Step 1 and consume it.

- [ ] **Step 3: Modal.** Create `domainsModal/index.tsx` — a `FloatingModal` with a `<select>` of the server's domains (default URL + declared). Per selected domain: *covered* → "Wildcard-covered by <base> — no DNS change needed."; *bare custom, IP set* → a copyable `A   <domain>   <hosting_public_ip>`; *bare custom, no IP* → `CNAME  <domain>  <default garnix URL>`. Reuse `CopyableCommand`.

- [ ] **Step 4: (i) button.** In the Connect cell add a small **(i)** button opening the modal (state in the row/page, like the existing Monitor button).

- [ ] **Step 5: Gates.** Backend compile gate → `Exit 0`; frontend tsc/lint/knip clean.

- [ ] **Step 6: Commit.** `git commit -am "feat(servers): (i) DNS-help modal for server domains"`

---

### Task 11: Docs — README + using-garnix-ci skill

**Files:**
- Modify: `README.md` (garnix-ci; Step 9 "Server deployments" area ~L657, and the SSH/expose subsection ~L764)
- Modify: `/home/joe/Development/agent-skills/skills/using-garnix-ci/SKILL.md`

- [ ] **Step 1: README.** Document: `garnix.yaml` `servers[].domains` (vanity vs bare custom); the operator `extraHostingDomains` + the required manual `*.<domain>` wildcard DNS; `hostingPublicIp`; the Configure "Connected domains" flow (add → set DNS → Verify = DNS-points-here); and the Servers (i) menu's A/CNAME records. One coherent "Custom & vanity domains" subsection.

- [ ] **Step 2: agent-skill.** In `using-garnix-ci/SKILL.md` add a short "Hosting custom/vanity domains" note mirroring the README (yaml field, operator bases, connected-domains, (i) menu), so the skill stays current.

- [ ] **Step 3: Commit** (garnix-ci): `git commit -am "docs: custom & vanity domains for hosted servers"`. Commit agent-skills separately in its repo and bump its flake input where consumed.

---

### Task 12: dotfiles wiring + input bump + final verification

**Files:**
- Modify: dotfiles `flake.lock` (bump `garnix-ci`), `modules/hosts/erdtree/garnix.nix` (Task 2 Step 6 values), `dotfiles-secrets/domains.nix` (Task 2 Step 5)
- Modify: agent-skills `flake.lock` bump wherever consumed (dotfiles + garnix-ci inputs), per the session convention

- [ ] **Step 1: Push garnix-ci `main`** with all prior tasks' commits.
- [ ] **Step 2: Bump inputs.** `nix flake update garnix-ci` (dotfiles) to the new rev; bump the agent-skills input where it's consumed.
- [ ] **Step 3: Commit dotfiles-secrets** (`garnixExtraHostingDomains`) + push.
- [ ] **Step 4: Eval erdtree.** `nix eval .#nixosConfigurations.erdtree.config.system.build.toplevel.drvPath` → resolves (validates the new options + env).
- [ ] **Step 5: Commit + push dotfiles** (input bump + erdtree wiring).
- [ ] **Step 6: Operator deploy (user-gated).** Note in the PR/summary: `just build-to-erdtree` applies the migrations + new env; the operator must add the manual `*.<domain>` wildcard DNS records for each `extraHostingDomains` entry, and A/CNAME records per the (i) menu for bare custom domains.

---

## Self-Review

**Spec coverage:** Component 1 → Task 1; Component 2 → Task 2; Component 3 → Tasks 3-5; Component 4 → Tasks 6-9; Component 5 → Task 10; Component 6 → Tasks 11-12. All covered.

**Placeholder scan:** Two deliberate implementation-time decisions remain (the jsonb `[Text]` decode approach in Task 3 Step 4 — resolved by mirroring `servers.exposed`; the `dns`-vs-`getAddrInfo` choice in Task 7 Step 1 — resolved to prefer `getAddrInfo`, no new dep). The erdtree public IP in Task 2 Step 6 is a lookup, not a placeholder. No "TODO/handle edge cases/add validation" left.

**Type consistency:** `Host._hostDomains :: [Text]` (Task 3) is consumed as `h ^. domains` in Tasks 4-5, 10. `DomainKind` (Task 4) is used only in Task 4/10 classification. `getVerifiedConnectedDomains :: M [Text]` (Task 6) matches the consumer in Task 4. `ConnectedDomainDto` fields (Task 8) match the zod schema keys in Task 9 (`id/domain/is_wildcard/verified`). `resolvesToHostingIp :: Text -> M Bool` (Task 7) matches the caller in Task 8. Consistent.
