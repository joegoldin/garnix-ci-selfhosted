# Self-Host-Only Fork + SSH-Access Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strip every non-self-hosted subsystem (Stripe/billing, product-plan limits, Hetzner Cloud) out of the `joegoldin/garnix-ci` fork so it is self-hosting-only, and redesign server SSH access into clean, composable `garnix.yaml` options.

**Architecture:** The fork already runs every limit/billing path through a `selfHostMode` short-circuit; this plan deletes the now-dead non-self-host arm rather than adding new bypasses. `ProductPlan` slims to just the eval/build timeouts (the Configure-page safety caps we keep). `LocalProvisioner` becomes the only provisioner; the `Hetzner*` seam/types are renamed to provisioner-neutral names. SSH access splits into an `exposeSSH` DNAT concern and separate key-authorization concerns, with the `garnix` guest user login-closed by default.

**Tech Stack:** Haskell/Servant, postgresql-typed, autodocodec (garnix.yaml), sqitch migrations, Next.js/zod frontend, Python provisioner daemon, microvm.nix/NixOS.

## Global Constraints

- Backend builds with `-Wall -Werror`; every field of a record literal must be initialised (`-Wmissing-fields`) and every generated lens exported or used (`-Wunused-top-binds`).
- **Authoritative gate:** `nix build '.#nixosConfigurations."erdtree".config.system.build.toplevel' --no-link --override-input garnix-ci "git+file:///home/joe/Development/garnix-ci?ref=self-hosting" --override-input dotfiles-secrets ... ` from `~/dotfiles` — OR, for speed, `nix develop -c bash -c 'export TPG_HOST/TPG_SOCK/TPG_PORT/TPG_USER/TPG_PASS/TPG_DB pointing at a running devshell pg; cd backend && cabal build lib:garnix'` (exit 0). Commit before the toplevel gate (git+file reads committed HEAD).
- Golden config schema at `backend/.golden/ConfigSchemaSpec/garnix-config-schema.json/golden` is regenerated from the compiled library: `cabal repl lib:garnix` then `BSL.writeFile "…/golden" (encodePretty garnixConfigJsonSchema)`. Autodocodec renders `Int` as `{minimum,maximum,type:integer}` and `[Text]` as `{items:{type:string},type:array}`; `required` arrays are reverse-codec-order.
- Cabal `exposed-modules` are DUPLICATED across two targets (~line 44 library, ~line 800 test) — add/remove modules in BOTH.
- `Env` and `ProductPlan`/`RunningServer`/`Host`/`ServerInfo`/`ServerToSpinUp`/`ServerSection` are positional or field-complete records: every construction site updates in lockstep. The one literal `Env {...}` is `backend/test/spec/Garnix/TestHelpers/Monad.hs`.
- KEEP, do not touch: usage tracking (`getCurrentMonthUsage(s)`, `getPrDeployDurationForOwner`, `getRunningBranchServersForOwner`, account usage endpoints), `applyConfiguredTimeouts`/`defaultBuildTimeoutMinutes` + the Configure page, `SubscriptionType`/`users.subscription_type` (admin role — NOT billing), `ServerTier`, `LocalProvisioner` behaviour, monitoring, the github/gitea `Forge` discriminator.
- **Full rename:** `HetznerServerId` → `ProvisionedServerId`; DB column `servers.hetzner_id`/`pre_provisioned_servers.hetzner_id` → `provisioner_id`. **Drop-via-migration:** dead tables/columns removed by sqitch.
- No secrets in the public fork; the erdtree wiring lives in `~/dotfiles` (user-gated deploys).

**Progress note:** Task 1 and part of Task 2 are already applied in the working tree (Entitlements rewritten, `ProductPlan` slimmed, `ExtraUsageLimits`/Stripe-id types removed, `StripeLib`/`StripeLib.Types`/`API.Stripe`/`MonetaryCost` deleted + pruned from cabal, `Hosting/Helpers.hs` billing removed). The build is currently red at `Hosting/ServerPool/Types.hs` (`serverTierToCost`). Resume from there.

---

### Task 1: Remove Stripe / billing (backend)

**Files:**
- Delete: `backend/src/Garnix/StripeLib.hs`, `backend/src/Garnix/StripeLib/Types.hs`, `backend/src/Garnix/API/Stripe.hs`, `backend/src/Garnix/MonetaryCost.hs` (done).
- Delete: `backend/test/spec/Garnix/StripeLibSpec.hs`, `backend/test/spec/Garnix/Hosting/BillingSpec.hs` (done).
- Modify: `backend/garnix.cabal` (both module lists — done), `backend/src/Garnix/Types.hs` (drop `CustomerId`/`InvoiceId`/`SubscriptionId`, `import Garnix.MonetaryCost` — done), `backend/src/Garnix/Hosting/Helpers.hs` (drop billing fns, keep `RunningServer`/`getRunningAndRecentServersForOwners` — done), `backend/src/Garnix/API.hs`, `backend/src/Garnix/Monad.hs`, `backend/src/Garnix.hs`, `backend/src/Garnix/API/Account.hs`, `backend/src/Garnix/DB.hs`.

**Interfaces produced:** none new; removes `StripeEnv`, `Env.stripe`, the six stripe `*Mock` fields + `StripeMocks` feature, the `/api/events/stripe` webhook route, and DB fns `updatePeriodForCustomer`/`getRepoOwnerForStripeCustomer`/`getInstallationStripeCustomer`/`setStripeCustomerId`.

- [ ] **Step 1: `API.hs`** — remove `import Garnix.API.Stripe`, the `events` route arm `:<|> "stripe" :> StripeWebhookAPI` (revert to just github+gitea), and the `:<|> stripeWebhookAPI` handler.
- [ ] **Step 2: `Monad.hs`** — remove `import Garnix.StripeLib.Types`; delete Env field `stripe :: StripeEnv`; delete `data StripeEnv`; delete the six mock fields (`createCustomerMock`,`createSubscriptionMock`,`createInvoiceItemMock`,`listSubscriptionsMock`,`cancelSubscriptionMock`,`getPriceMock`) and their `emptyMocks` entries; remove `StripeMocks` from the feature enum.
- [ ] **Step 3: `Garnix.hs`** — remove the `STRIPE_*` env reads and the `stripe = StripeEnv{…}` line in the `Env` literal.
- [ ] **Step 4: `DB.hs`** — delete `updatePeriodForCustomer`, `getRepoOwnerForStripeCustomer`, `getInstallationStripeCustomer`, `setStripeCustomerId`.
- [ ] **Step 5: `API/Account.hs`** — delete the billing routes+handlers: `_accountAPIUpgradeOption`/`getUpgradeOptionByToken`, `_accountAPITaxes`/`taxes`, `_accountAPISubscribe`/`createSubscription`, `_accountAPIUnsubscribe`/`cancelOrgSubscription`, `handleSubscriptionAdded`, `handleInvoiceCreated`+`billOverage`, `upgradeOptions`/`upgradeOptionsFromDb`, `UpgradeOption`, `setUsageLimits`. KEEP `usageOverview`/`orgUsage`/`getUsageForOrg`. Drop `_orgUsageUpgradeOption` from `OrgUsage`.
- [ ] **Step 6: Gate** (`cabal build lib:garnix`) — expect the cascade to continue into Task 2/3 symbols; fix Task-1-only breaks here.
- [ ] **Step 7: Commit** `refactor(self-host): remove Stripe billing + webhooks`.

### Task 2: Remove plan limits / entitlements

**Files:**
- Modify: `backend/src/Garnix/Types.hs` (`ProductPlan` slimmed to `_productPlanDisplayName`,`_productPlanDescription`,`_productPlanPackageEvaluationTimeout`,`_productPlanPackageBuildTimeout` — done), `backend/src/Garnix/Entitlements.hs` (rewritten to `getPlan`/`defaultProductPlan`/`applyConfiguredTimeouts`/`defaultBuildTimeoutMinutes` — done).
- Modify: `backend/src/Garnix/Hosting/ServerPool/Types.hs`, `backend/src/Garnix/Build/Flake.hs`, `backend/src/Garnix/Hosting/Deploy.hs`, `backend/src/Garnix/API/Account.hs`, `backend/src/Garnix/DB.hs`.

**Interfaces produced:** `Entitlements.getPlan :: GhRepoOwner -> M ProductPlan` (returns `defaultProductPlan`, timeouts `maxBound`), `applyConfiguredTimeouts :: RepoConfig -> ProductPlan -> M ProductPlan`, `defaultBuildTimeoutMinutes :: Int32`.

- [ ] **Step 1: `ServerPool/Types.hs`** — delete `serverTierToCost` and its `import Garnix.MonetaryCost`. (This is the current red edge.)
- [ ] **Step 2: `Build/Flake.hs`** — remove the CI-quota gate (the `hasRemainingCiTime` check that throws "exhausted your monthly CI quota") and the packages-per-flake limit (`plan ^. maximumPackagesPerFlake`). Keep `getPlan >>= applyConfiguredTimeouts`. Drop the now-unused imports (`hasRemainingCiTime`, `addDefaultEntitlements`, `maximumPackagesPerFlake`).
- [ ] **Step 3: `Hosting/Deploy.hs`** — delete `checkEntitlement` (host-count/PR-minute/spend gate), `checkServerTiers`, `totalDeploymentCost`, `_costBreakdown`, `DeployCounts`; remove their call sites and `import Garnix.MonetaryCost`/`Garnix.Entitlements (getHosting…)`. Deploy no longer gates on entitlements.
- [ ] **Step 4: `API/Account.hs`** — the usage endpoints keep a `plan` for display only. Replace any `getPlans`/`getHosting`/`getPlanByProductToken`/`setExtraUsageLimits` calls with `Entitlements.getPlan`/`defaultProductPlan`; drop the plan-page endpoints that exposed limits.
- [ ] **Step 5: `DB.hs`** — no plan tables are read anymore; ensure no `products`/`repo_owner_has_product`/`repo_owner_usage_limits` query remains (they move to Task 4's DROP).
- [ ] **Step 6: Gate + Commit** `refactor(self-host): remove product-plan limits, keep Configure timeouts`.

### Task 3: Remove Hetzner Cloud + full rename

**Files:**
- Delete: `backend/src/Garnix/HetznerInterface.hs`, `backend/test/spec/Garnix/HetznerInterfaceSpec.hs`, `backend/test/spec/Garnix/TestHelpers/HetznerMock.hs`; prune all three from `garnix.cabal` (both lists).
- Modify: `backend/src/Garnix/Monad.hs`, `backend/src/Garnix.hs`, `backend/src/Garnix/LocalProvisioner.hs`, `backend/src/Garnix/Hosting/ServerPool/Types.hs`, `backend/src/Garnix/Hosting/ServerPool.hs`, `backend/src/Garnix/Hosting/Deploy.hs`, `backend/src/Garnix/API/Hosts.hs`, `backend/src/Garnix/Types.hs`, `backend/src/Garnix/DB.hs`.

**Interfaces produced:** `data Provisioner` (was `HetznerInterface`) with `_provisionerProvisionServer`/`_provisionerUpdateMetadata`/`_provisionerDeleteServer`/`_provisionerGetServerStatus`; `newtype ProvisionedServerId` (was `HetznerServerId`); Env `provisioner :: Provisioner` (was `hetznerInterface`).

- [ ] **Step 1:** In `Monad.hs` rename `data HetznerInterface` → `Provisioner`, its four `_hetznerInterface*` fields → `_provisioner*`, the Env field `hetznerInterface` → `provisioner`, and the wrapper actions `provisionServer`/`updateMetadata`/`deleteServer`/`getServerStatus` to `view #provisioner`. Delete Env `hetznerToken`. Delete `waitTillServerIsInitializedMock` if Hetzner-only (keep if the pool uses it — check `ServerPool.hs`).
- [ ] **Step 2:** In `Types.hs` rename `newtype HetznerServerId` → `ProvisionedServerId` (+ its `Pretty`, `PGColumn`), and the struct fields `_serverInfoHetznerServerId`→`_serverInfoProvisionedServerId`, `_preprovisionedServerHetznerServerId`→`_preprovisionedServerProvisionedServerId`, `_hostHetznerId`→`_hostProvisionerId`. Update every `makeFields` consumer (`^. hetznerServerId` → `^. provisionedServerId`, etc.).
- [ ] **Step 3:** In `ServerPool/Types.hs` delete `data HetznerServerType`, `hetznerServerTypeToName`, `data HetznerLocation`, `hetznerLocationToName`, `serverTierToHetznerServerType`. Replace with a single `tierResources :: ServerTier -> (Int, Int)` (vcpu, mem-MiB) — move the map from `LocalProvisioner.hs`.
- [ ] **Step 4:** In `LocalProvisioner.hs` drop `realHetznerInterface`-shaped names; `localProvisionerInterface` builds a `Provisioner`; `provisionServer'` takes `ServerTier` (via `tierResources`) instead of `HetznerServerType`; reuse `ProvisionedServerId`. Rename the module's `exposeServer`'s `ProvisionedServerId` param.
- [ ] **Step 5:** In `Garnix.hs` `provisioner = localProvisionerInterface (requireProvisionerSocket …)` — the socket is now mandatory (self-host only); error at startup if `GARNIX_PROVISIONER_SOCKET` is unset. Delete the `maybe realHetznerInterface …` selection and `HETZNER_TOKEN` reads.
- [ ] **Step 6:** In `ServerPool.hs`/`Deploy.hs`/`API/Hosts.hs` update signatures using `HetznerServerId`→`ProvisionedServerId`; `stopServer :: ServerId -> ProvisionedServerId -> M ()`; `DB.getHetznerServerById`→`DB.getProvisionerServerById`.
- [ ] **Step 7:** In `DB.hs` rename the `hetzner_id` column references in queries to `provisioner_id` (matches Task 4 migration); rename `getHetznerServerById`→`getProvisionerServerById`.
- [ ] **Step 8: Gate + Commit** `refactor(self-host): drop Hetzner Cloud; LocalProvisioner is the only provisioner (rename to Provisioner/ProvisionedServerId)`.

### Task 4: DB migrations — drop dead tables/columns + rename column + usage query

**Files:**
- Create: `sql/deploy/drop-billing-and-plans.sql`, `sql/deploy/rename-hetzner-id-to-provisioner-id.sql`; modify `sql/sqitch.plan`, `sql/deploy/init.sql`.
- Modify: `backend/src/Garnix/DB.hs` (`getCurrentMonthUsages`).

- [ ] **Step 1:** `drop-billing-and-plans.sql` (wrap in `BEGIN;`/`COMMIT;`): `DROP TABLE IF EXISTS repo_owner_has_product; DROP TABLE IF EXISTS repo_owner_usage_limits; DROP TABLE IF EXISTS products;` and `ALTER TABLE installations DROP COLUMN IF EXISTS stripe_customer, DROP COLUMN IF EXISTS current_period_start, DROP COLUMN IF EXISTS current_period_end, DROP COLUMN IF EXISTS requested_cancellation; ALTER TABLE builds DROP COLUMN IF EXISTS comped;`.
- [ ] **Step 2:** `rename-hetzner-id-to-provisioner-id.sql`: `ALTER TABLE servers RENAME COLUMN hetzner_id TO provisioner_id; ALTER TABLE pre_provisioned_servers RENAME COLUMN hetzner_id TO provisioner_id;` and drop the `ready_must_have_hetzner_id_and_ips` CHECK if it names the column, re-adding as `provisioner_id`.
- [ ] **Step 3:** Add both to `sql/sqitch.plan` (after `add-servers-exposed`) with ISO timestamps; mirror the schema changes into `sql/deploy/init.sql` (drop the three tables' CREATEs + the stripe/comped columns; rename the column in the two CREATE TABLEs).
- [ ] **Step 4:** `DB.getCurrentMonthUsages` — remove the `installations` LEFT JOIN for `current_period_start/end` and the `comped = false` filter; bucket by calendar month (`date_trunc('month', now())`) instead. Verify against the running pg after applying the migrations.
- [ ] **Step 5: Gate** (the migration must apply cleanly in the typed-sql sandbox — apply the deploy SQLs to the dev pg first) **+ Commit** `feat(db): drop billing/plan tables + rename hetzner_id→provisioner_id`.

### Task 5: SSH-access redesign

**Files:**
- Modify: `backend/src/Garnix/YamlConfig.hs` (`ServerSection`), `backend/.golden/.../golden`, `backend/src/Garnix/Types.hs` (`ServerToSpinUp`), `backend/src/Garnix/Hosting/Deploy.hs`, `backend/src/Garnix/Hosting/Helpers.hs` (or wherever `exposed` blob is read for `ssh_user`), `provisioner/guest-profile.nix`, `frontend/src/services/servers.ts`, `frontend/src/app/servers/page.tsx`, `backend/test/spec/Garnix/YamlConfigSpec.hs`, `backend/test/spec/Garnix/DeploySpec.hs`, `backend/test/spec/Garnix/Hosting/ServerPoolSpec.hs`.

**Interfaces produced:** `ServerSection` gains `_serverSectionExposeSSH :: Bool` (rename of `_serverSectionSshExpose`), `_serverSectionAuthorizeDeployerGithubKeys :: Bool` (new), `_serverSectionAuthorizedSSHKeys :: [Text]` (rename of `_serverSectionSshKeys`), keeps `_serverSectionPorts`. `ServerToSpinUp` mirrors: `exposeSSH :: Bool`, `authorizeDeployerGithubKeys :: Bool`, `authorizedSSHKeys :: [Text]`, `httpPorts`, `tcpPorts`.

- [ ] **Step 1: yaml schema** — in `YamlConfig.hs` rename `sshExpose`→`exposeSSH` (`optionalFieldWithDefault "exposeSSH" False "Open a public DNAT port -> the guest's SSH (:22)."`), rename `sshKeys`→`authorizedSSHKeys` (`optionalFieldWithDefault "authorizedSSHKeys" [] "Public keys authorized to log in as the garnix user."`), add `authorizeDeployerGithubKeys` (`optionalFieldWithDefault "authorizeDeployerGithubKeys" False "Authorize the deployer's github.com/<user>.keys to log in as the garnix user."`). Update the exported makeFields lenses (`exposeSSH`,`authorizeDeployerGithubKeys`,`authorizedSSHKeys`), keeping the `Garnix.Types hiding (...)` guard for any name that collides with a `ServerToSpinUp` selector.
- [ ] **Step 2: golden** — regenerate via `cabal repl` (see Global Constraints); the `servers` properties gain `authorizeDeployerGithubKeys`(boolean), `authorizedSSHKeys`(array/string), `exposeSSH`(boolean), lose `sshExpose`/`sshKeys`.
- [ ] **Step 3: `ServerToSpinUp` + Deploy wiring** — rename the fields; in `Deploy.hs`, `wantsExposure = exposeSSH || not (null tcpPorts)` gates the DNAT (`exposeServerPorts`); `wantsGarnixKeys = authorizeDeployerGithubKeys || not (null authorizedSSHKeys)` gates `copyAuthorizedKeys`. `copyAuthorizedKeys` gathers keys = (if `authorizeDeployerGithubKeys` then `fetchGithubKeys deployer` else `pure []`) `++ authorizedSSHKeys`, writes them iff non-empty. The persisted `exposedBlob` gains `ssh_user = if wantsGarnixKeys then Just "garnix" else Nothing`.
- [ ] **Step 4: guest hardening** — in `guest-profile.nix` add `services.openssh.settings.PasswordAuthentication = false; services.openssh.settings.KbdInteractiveAuthentication = false;`; the `garnix` user stays `openssh.authorizedKeys.keyFiles = [ "/var/garnix/keys/authorized_keys" ]` (login-closed when the file is absent) + the hosting key for deploys; no password.
- [ ] **Step 5: RunningServer / Servers page** — `servers.ts` `exposed` schema gains `ssh_user: z.string().nullish()`; `page.tsx` `ConnectCell` uses `server.exposed?.ssh_user ?? "<user>"` as the ssh login name in the Tailscale/ProxyJump/Port-forward commands (so a manually-declared user shows `<user>@…` and an authorized garnix user shows `garnix@…`).
- [ ] **Step 6: fixtures** — update `YamlConfigSpec`/`DeploySpec`/`ServerPoolSpec` `ServerSection`/`ServerToSpinUp` constructions to the new field order/arity.
- [ ] **Step 7: Gate + Commit** `feat(servers): exposeSSH / authorizeDeployerGithubKeys / authorizedSSHKeys; hardened login-closed garnix user`.

### Task 6: Frontend billing / plan removal

**Files:**
- Delete: `frontend/src/app/account/manage_plans/page.tsx`, `frontend/src/app/account/manage_plans/styles.module.css`, `frontend/src/components/icons/billing.tsx`.
- Modify: `frontend/src/services/account.ts`, `frontend/src/app/account/gh/[slug]/page.tsx`, `frontend/src/middleware.ts`, `frontend/package.json`.

- [ ] **Step 1: `services/account.ts`** — remove `UpgradeOption`/`upgradeOptionSchema`, `mkStripeOptions`, `getTaxCalculation`/`TaxCalculation`, `submitPaymentInformation`, `confirmPayment`, `getUpgradeOptionByToken`, `setUsageLimits`, `cancelPlan`, and the `@stripe/*` imports. Slim `planSchema` to `{ display_name, description }`. KEEP `getAccountUsage`/`getOrgUsage`/`getRepos`/access-token fns.
- [ ] **Step 2: `account/gh/[slug]/page.tsx`** — keep the usage meters; remove the Upgrade link, `CancelPlanButton`, the `UsageLimits` form, the subscription/`is_paid` copy. Since `selfHostMode` already hides these, this is deleting the now-unreachable branch.
- [ ] **Step 3: `middleware.ts`** — drop `api.stripe.com`/`js.stripe.com`/`hooks.stripe.com` from the CSP allow-lists.
- [ ] **Step 4: `package.json`** — remove `@stripe/react-stripe-js`, `@stripe/stripe-js`; run the lock update the repo uses (npm/pnpm) so the nix frontend build stays reproducible.
- [ ] **Step 5: Gate** `nix build .#frontend_default` **+ Commit** `refactor(frontend): remove billing/plan UI + Stripe deps`.

### Task 7: Nix / secrets cleanup

**Files:** `backend/nixos-module.nix`, `nix/packages/withSecrets.nix`, `secrets/dev.yaml`.

- [ ] **Step 1: `nixos-module.nix`** — remove the `hetzner-token`, `stripe-publishable-key`, `stripe-secret-key`, `stripe-webhook-secret` sops secret declarations; remove `StripeMocks` from the `extraFeatures` enum; `provisionerSocket` becomes required (or keep nullable but the backend errors when unset).
- [ ] **Step 2: `withSecrets.nix`** — drop the `HETZNER_TOKEN` and `STRIPE_*` `export` lines.
- [ ] **Step 3: `secrets/dev.yaml`** — remove the `hetzner-token` + `stripe-*` encrypted entries.
- [ ] **Step 4: Gate** (module eval via the toplevel gate) **+ Commit** `chore(nix): drop hetzner/stripe secrets + StripeMocks feature`.

### Task 8: Tests cleanup

**Files:** `backend/test/spec/Garnix/**` (delete dead specs, fix survivors), `backend/test/spec/Garnix/TestHelpers/*`, `backend/garnix.cabal` (test module list).

- [ ] **Step 1:** Delete already-removed specs from the cabal test list (`StripeLibSpec`, `Hosting.BillingSpec`, `EntitlementsSpec`, `HetznerInterfaceSpec`) and delete `TestHelpers/HetznerMock.hs`; excise its uses in `TestHelpers/Deprecated.hs`/`Monad.hs`/`ServerPool.hs`/`TestHelpers.hs` (the `hetznerToken`/`STRIPE_*`/`testHetznerInterface`/`StripeEnv` literals).
- [ ] **Step 2:** Fix the residual forge/type breakage the rename surfaces across `DBSpec`/`MonadSpec`/`GithubReporterSpec`/`DeploySpec`/`API/*Spec` (`_repoInfoForge`/`_buildForge` already fixed in the core helpers; apply the same to any remaining literals). Update `HostList`/`RunningServer`/`ServerSection`/`ServerToSpinUp` fixtures for the new shapes.
- [ ] **Step 3: Gate** `cabal build test:spec` then `cabal test` (golden passes) **+ Commit** `test: drop billing/hetzner specs; fix fixtures for self-host-only shapes`.

### Task 9: README / cookbooks

**Files:** `README.md`, `docs/authentik-cookbook.md`, `examples/hello-server/flake.nix`.

- [ ] **Step 1: `README.md`** — reframe "What this fork adds vs upstream" as self-hosting-only (no billing/plans/Hetzner); rewrite the SSH section to document `exposeSSH`/`authorizeDeployerGithubKeys`/`authorizedSSHKeys` + the login-closed garnix user + the manual user-in-guest route; note the Servers page `ssh_user`/Connect column; update the deploy prerequisites (no hetzner/stripe secrets).
- [ ] **Step 2: `examples/hello-server/flake.nix`** — show the manual user route (`users.users.<me>` with keys) + `exposeSSH = true`, matching what `garnix-hello` now does.
- [ ] **Step 3: `docs/authentik-cookbook.md`** — verify the authentik boilerplate still matches (`authentik: default` + `garnix-authentik` `mode = "default"`); refresh any plan/billing mention.
- [ ] **Step 4: Commit** `docs: self-host-only README + SSH access + example`.

### Task 10: `using-garnix-ci` agent skill update

**Files:** the `using-garnix-ci` skill in `~/Development/agent-skills` (locate via the skill dir).

- [ ] **Step 1:** Find the skill (`grep -rl garnix ~/Development/agent-skills`). Update it to reflect: self-hosting-only fork (no billing/plans/Hetzner); the authentik auth boilerplate (`authentik: default` gate, `garnix-authentik` guest module modes dedicated/default/shared); the microVM hosting model + `garnix-guest`/`garnix-authentik` nixosModules; server SSH access (`exposeSSH`/`authorizeDeployerGithubKeys`/`authorizedSSHKeys` + manual user route); the monitoring page; the Configure page timeouts; `exposeSSH`/`ports` networking.
- [ ] **Step 2: Commit** in the agent-skills repo `docs(using-garnix-ci): update for self-host-only fork + authentik + ssh + monitoring`.

### Task 11: Fix per-module Documentation links on the Modules page

**Files:** `frontend/src/app/modules/configure/**` (the per-module card/selector that renders each module's Documentation + Source links — `grep -rn "github.com\|/docs\|Documentation\|repo_user" frontend/src/app/modules` to locate it; the Source link already builds `https://github.com/<repo_user>/<repo_name>` correctly).

**Problem:** Each module's **Documentation** link points at bare/upstream `garnix.io`, while the **Source** link correctly points at the user's forks. The Documentation link should point at the per-module docs at `https://garnix.io/docs/modules/<module-name>` (matching how Source is derived from the module's repo).

- [ ] **Step 1:** Locate where the module Documentation link href is constructed (module metadata has `name`, `repo_user`, `repo_name`, `git_commit`). Confirm the current (wrong) target against the live page.
- [ ] **Step 2:** Build the href as `https://garnix.io/docs/modules/${module.name}` (open in a new tab, `rel="noopener noreferrer"`). Keep the Source link (`https://github.com/${repo_user}/${repo_name}`) unchanged. If a configurable docs base is preferred over hardcoding, thread it from `/api/config` — but default to `https://garnix.io/docs/modules/`.
- [ ] **Step 3: Gate** `nix build .#frontend_default` **+ Commit** `fix(modules): point per-module Documentation links at /docs/modules/<name>`.

## Self-review notes
- **Spec coverage:** billing (T1,T4,T6,T7) · plan limits (T2,T4) · Hetzner+rename (T3,T4,T7) · usage-query rewrite (T4) · SSH redesign+hardening+ssh_user (T5) · frontend (T6) · nix/secrets (T7) · tests (T8) · README/cookbooks (T9) · skill (T10) · module Documentation links (T11). No gap.
- **KEEP list honoured:** usage tracking, Configure timeouts, `SubscriptionType`, `ServerTier`, `LocalProvisioner`, monitoring, forge — none deleted.
- **Type consistency:** `ProductPlan` fields, `Provisioner`/`ProvisionedServerId`, `exposeSSH`/`authorizeDeployerGithubKeys`/`authorizedSSHKeys`, `provisioner_id` used identically across tasks.
- **Ordering:** T1→T2 (both touch `ProductPlan`/billing) before T3 (rename) before T4 (migration matching T3's column names); T5 independent but shares `ServerSection`/`ServerToSpinUp` with fixtures; frontend/nix/tests/docs last.
