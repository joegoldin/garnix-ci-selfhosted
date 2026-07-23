# Elastic, Budget-Bounded microVM Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the static per-tier warm pool with an elastic provisioner that provisions **any** requested tier **on demand**, keeps recently-used tiers warm, and bounds total guest **RAM and vCPUs** by a configurable budget (absolute *or* reserve), evicting idle pooled VMs and then queueing deploys when a budget is hit.

**Architecture:** The NixOS module gains `hosting.memoryBudget`/`hosting.cpuBudget` options rendered to env. At startup the backend resolves reserve-style budgets to absolute caps using host totals (`/proc/meminfo`, `getNumProcessors`) and stores them in `Env`. A new resource-accounting query sums committed `(vcpu, mib)` over active `servers` + all `server_pool` rows. `ServerPool.createServer` gains an on-demand path: on a claim miss it provisions the requested tier when within budget, else evicts an idle **ready** pooled VM to free room, else waits (surfacing a wait reason). The refill loop keeps tiers warm only within remaining budget.

**Tech Stack:** Haskell/Servant backend (`postgresql-typed` — SQL typechecks against a live PG at compile time; build via `nix build .#backend_garnixHaskellPackage`, never bare `cabal build`), PostgreSQL 18, NixOS module, `microvm.nix` provisioner (`garnix-provisionerd`).

## Global Constraints

- **Backward compatible:** all budgets are `Maybe` — `Nothing` = unbounded, preserving current behavior when unset. The existing `serverPool` static warm-counts option keeps working (it becomes the *keep-warm target*, clamped to the budget).
- **Single-tenant threat model:** owner + trusted friends; no multi-tenant fairness needed. Budgets are a resource-safety guard, not an anti-abuse quota.
- **Compile gate before every commit:** `nix build .#backend_garnixHaskellPackage --no-link --print-out-paths`; check exit status directly (do not pipe through `tail`). On failure read `nix log /nix/store/<hash>-garnix-0.1.0.0.drv`.
- **New files must be `git add`ed** (git-repo flake excludes untracked files from source).
- **Migrations:** none required — both `servers` and `server_pool` already carry `server_tier`.
- **Resource unit conventions:** memory in **MiB** everywhere in the backend (matches `tierResources`); vCPUs as plain ints. Nix options are authored in GiB/cores for humans and converted at render time.
- **Reserve semantics:** a *reserve* budget of `R` means "keep `R` free on the host"; resolved cap = `hostTotal − R`. An *absolute* budget of `A` means "guests may use at most `A` total"; resolved cap = `A`.

---

## File Structure

- `backend/src/Garnix/Hosting/ServerPool/Types.hs` — add `tierVcpus`/`tierMiB` accessors + a pure `ResourceBudget`/`Committed` model and the `fitsBudget`/`sumTierResources` helpers. Pure, unit-testable.
- `backend/src/Garnix/Hosting/Budget.hs` *(new)* — parse the budget env strings, resolve reserve→absolute against host totals (`hostTotalMiB`, `hostVcpus`). Pure parse + thin IO for host detection.
- `backend/src/Garnix/Monad.hs` — add `hostingMemBudgetMiB :: Maybe Int` and `hostingVcpuBudget :: Maybe Int` to `Env`.
- `backend/src/Garnix.hs` — read `GARNIX_HOSTING_MEM_BUDGET`/`GARNIX_HOSTING_CPU_BUDGET`, resolve, inject into `Env` (mirrors the `GARNIX_SERVER_POOL` block at `Garnix.hs:342-446`).
- `backend/src/Garnix/DB.hs` — `committedResources :: M Committed` (sum active servers + pool) and `claimIdleReadyPoolVMForEviction :: (Int,Int) -> M (Maybe PreprovisionedServer)` (pick an idle ready pool row to destroy for headroom).
- `backend/src/Garnix/Hosting/ServerPool.hs` — budget-aware `refill` (keep-warm within budget), on-demand provisioning + eviction + wait loop in `createServer`, and a shared `provisionOne` helper factored out of the refill loop.
- `backend/nixos-module.nix` — `hosting.memoryBudget`/`hosting.cpuBudget` options + env rendering.
- `backend/test/spec/Garnix/Hosting/BudgetSpec.hs` *(new)* — pure parse/resolve/fits tests.
- `backend/test/spec/Garnix/Hosting/ServerPoolSpec.hs` — extend (or create) with mocked-provisioner budget/eviction/on-demand tests.
- `docs/hosting.md` (or the `using-garnix-ci` skill / nixos-module option docs) — document the budgets.

---

### Task 1: Pure tier-resource + budget model

**Files:**
- Modify: `backend/src/Garnix/Hosting/ServerPool/Types.hs`
- Test: `backend/test/spec/Garnix/Hosting/BudgetSpec.hs` (created here, extended in Task 2)

**Interfaces:**
- Produces:
  - `tierVcpus :: ServerTier -> Int`, `tierMiB :: ServerTier -> Int` (thin wrappers over existing `tierResources`).
  - `data Committed = Committed { committedVcpus :: Int, committedMiB :: Int }` with a `Monoid` instance (sums).
  - `sumTierResources :: [(ServerTier, Int)] -> Committed` (count-weighted sum).
  - `data ResourceBudget = ResourceBudget { budgetVcpus :: Maybe Int, budgetMiB :: Maybe Int }` (resolved absolute caps; `Nothing` = unbounded).
  - `fitsBudget :: ResourceBudget -> Committed -> ServerTier -> Bool` — true iff adding one guest of the tier keeps both dims `<=` their cap (a `Nothing` cap always fits).

- [ ] **Step 1: Write failing tests** in `backend/test/spec/Garnix/Hosting/BudgetSpec.hs`

```haskell
module Garnix.Hosting.BudgetSpec (spec) where

import Garnix.Hosting.ServerPool.Types
import Garnix.Prelude
import Test.Hspec

spec :: Spec
spec = describe "budget model" $ do
  it "sums count-weighted tier resources" $
    sumTierResources [(I2x4, 2), (I1x1, 1)]
      `shouldBe` Committed {committedVcpus = 2 * 2 + 1, committedMiB = 2 * 4096 + 1024}

  it "fits when both dims stay within the caps" $
    fitsBudget (ResourceBudget (Just 4) (Just 8192)) (Committed 2 4096) I2x4 `shouldBe` True

  it "rejects when the memory cap would be exceeded" $
    fitsBudget (ResourceBudget (Just 8) (Just 6144)) (Committed 2 4096) I2x4 `shouldBe` False

  it "rejects when the vcpu cap would be exceeded" $
    fitsBudget (ResourceBudget (Just 3) (Just 65536)) (Committed 2 4096) I2x4 `shouldBe` False

  it "an unset cap always fits that dimension" $
    fitsBudget (ResourceBudget Nothing Nothing) (Committed 999 999999) I16x32 `shouldBe` True
```

- [ ] **Step 2: Run to verify failure**

Run: `nix build .#backend_garnixHaskellPackage 2>&1` (BudgetSpec/new symbols won't resolve).
Expected: FAIL — `Variable not in scope: sumTierResources` etc.

- [ ] **Step 3: Implement** in `Garnix/Hosting/ServerPool/Types.hs` (append):

```haskell
tierVcpus :: ServerTier -> Int
tierVcpus = fst . tierResources

tierMiB :: ServerTier -> Int
tierMiB = snd . tierResources

data Committed = Committed {committedVcpus :: Int, committedMiB :: Int}
  deriving (Eq, Show)

instance Semigroup Committed where
  Committed a b <> Committed c d = Committed (a + c) (b + d)

instance Monoid Committed where
  mempty = Committed 0 0

sumTierResources :: [(ServerTier, Int)] -> Committed
sumTierResources =
  foldMap (\(tier, n) -> Committed (tierVcpus tier * n) (tierMiB tier * n))

-- | Resolved (absolute) budget caps. 'Nothing' means unbounded in that dim.
data ResourceBudget = ResourceBudget
  { budgetVcpus :: Maybe Int,
    budgetMiB :: Maybe Int
  }
  deriving (Eq, Show)

-- | Would adding one guest of this tier keep BOTH dims within their caps?
fitsBudget :: ResourceBudget -> Committed -> ServerTier -> Bool
fitsBudget (ResourceBudget capV capM) (Committed v m) tier =
  within capV (v + tierVcpus tier) && within capM (m + tierMiB tier)
  where
    within Nothing _ = True
    within (Just cap) x = x <= cap
```

- [ ] **Step 4: Register the spec** — if the suite uses `hspec-discover` (check `backend/test/spec/Spec.hs`), the module is auto-discovered by path; otherwise add `Garnix.Hosting.BudgetSpec` to the discovery list. Confirm by grepping `hspec-discover` in `backend/garnix.cabal`/`Spec.hs`.

- [ ] **Step 5: Run to verify pass**

Run: `nix build .#backend_garnixHaskellPackage 2>&1`; then run the suite matching `--match "budget model"` (see Task 6 for the dev-shell runner). Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/src/Garnix/Hosting/ServerPool/Types.hs backend/test/spec/Garnix/Hosting/BudgetSpec.hs
git commit -m "hosting: pure tier-resource + ResourceBudget model with fitsBudget"
```

---

### Task 2: Budget env parsing + reserve→absolute resolution

**Files:**
- Create: `backend/src/Garnix/Hosting/Budget.hs`
- Modify: `backend/garnix.cabal` (add the module to `library` exposed-modules)
- Test: `backend/test/spec/Garnix/Hosting/BudgetSpec.hs` (extend)

**Interfaces:**
- Consumes: `ResourceBudget`, `Committed` (Task 1).
- Produces:
  - `data BudgetSpec = Absolute Int | Reserve Int` (units: MiB for memory, cores for cpu).
  - `parseBudget :: Text -> Maybe BudgetSpec` — parses the env encoding `"total:<n>"` / `"reserve:<n>"` (n is MiB or cores; already numeric — GiB→MiB conversion happens in nix at render time).
  - `resolveBudget :: Int -> Maybe BudgetSpec -> Maybe Int` — given the host total for that dimension, resolve to an absolute cap (`Absolute a → Just a`; `Reserve r → Just (max 0 (hostTotal - r))`; `Nothing → Nothing`).
  - `hostTotalMiB :: IO Int` (parse `MemTotal` from `/proc/meminfo`, kB→MiB), `hostVcpus :: IO Int` (`GHC.Conc.getNumProcessors`).

- [ ] **Step 1: Write failing tests** (append to `BudgetSpec.hs`):

```haskell
  describe "budget env parsing" $ do
    it "parses an absolute budget" $
      parseBudget "total:65536" `shouldBe` Just (Absolute 65536)
    it "parses a reserve budget" $
      parseBudget "reserve:81920" `shouldBe` Just (Reserve 81920)
    it "rejects malformed input" $
      parseBudget "80G" `shouldBe` Nothing

  describe "reserve resolution" $ do
    it "absolute passes through" $
      resolveBudget 128000 (Just (Absolute 65536)) `shouldBe` Just 65536
    it "reserve subtracts from the host total" $
      resolveBudget 128000 (Just (Reserve 81920)) `shouldBe` Just (128000 - 81920)
    it "reserve never goes negative" $
      resolveBudget 1024 (Just (Reserve 4096)) `shouldBe` Just 0
    it "unset stays unbounded" $
      resolveBudget 128000 Nothing `shouldBe` Nothing
```

- [ ] **Step 2: Run to verify failure** — `nix build .#backend_garnixHaskellPackage 2>&1`. Expected: FAIL (module/symbols missing).

- [ ] **Step 3: Implement** `Garnix/Hosting/Budget.hs`:

```haskell
module Garnix.Hosting.Budget
  ( BudgetSpec (..),
    parseBudget,
    resolveBudget,
    hostTotalMiB,
    hostVcpus,
  )
where

import Data.Text qualified as T
import GHC.Conc (getNumProcessors)
import Garnix.Prelude

data BudgetSpec = Absolute Int | Reserve Int
  deriving (Eq, Show)

parseBudget :: Text -> Maybe BudgetSpec
parseBudget s = case T.splitOn ":" (T.strip s) of
  ["total", n] -> Absolute <$> readMaybe (cs n)
  ["reserve", n] -> Reserve <$> readMaybe (cs n)
  _ -> Nothing

resolveBudget :: Int -> Maybe BudgetSpec -> Maybe Int
resolveBudget _ Nothing = Nothing
resolveBudget _ (Just (Absolute a)) = Just a
resolveBudget hostTotal (Just (Reserve r)) = Just (max 0 (hostTotal - r))

-- | Host RAM in MiB, from /proc/meminfo MemTotal (reported in kB).
hostTotalMiB :: IO Int
hostTotalMiB = do
  contents <- readFile "/proc/meminfo"
  let kb =
        listToMaybe
          [ n
            | line <- lines contents,
              ["MemTotal:", v, "kB"] <- [words line],
              Just n <- [readMaybe v]
          ]
  pure $ maybe 0 (`div` 1024) kb

hostVcpus :: IO Int
hostVcpus = getNumProcessors
```

- [ ] **Step 4:** Add `Garnix.Hosting.Budget` to `backend/garnix.cabal` `exposed-modules`. `git add` the new file.

- [ ] **Step 5: Run to verify pass** — build + `--match "budget env parsing"` + `--match "reserve resolution"`. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/src/Garnix/Hosting/Budget.hs backend/garnix.cabal backend/test/spec/Garnix/Hosting/BudgetSpec.hs
git commit -m "hosting: parse RAM/vCPU budget env + resolve reserve against host totals"
```

---

### Task 3: Wire budgets into `Env` + startup

**Files:**
- Modify: `backend/src/Garnix/Monad.hs` (add two `Env` fields, ~line 79 area)
- Modify: `backend/src/Garnix.hs` (read/resolve/inject, near the `GARNIX_SERVER_POOL` block `342-446`)

**Interfaces:**
- Consumes: `parseBudget`, `resolveBudget`, `hostTotalMiB`, `hostVcpus` (Task 2).
- Produces: `Env` fields `hostingMemBudgetMiB :: Maybe Int`, `hostingVcpuBudget :: Maybe Int`; a helper `hostingBudget :: M ResourceBudget` reading them from the reader env.

- [ ] **Step 1:** Add fields to `Env` (`Monad.hs`), right after `serverPoolConfig`:

```haskell
    serverPoolConfig :: [(ServerTier, Int)],
    -- | Resolved absolute caps on TOTAL guest RAM (MiB) / vCPUs across all
    -- active + pooled + in-flight guests. Nothing = unbounded (legacy).
    hostingMemBudgetMiB :: Maybe Int,
    hostingVcpuBudget :: Maybe Int,
```

- [ ] **Step 2:** Add the reader helper (in `Monad.hs`, near other `view`-based accessors):

```haskell
hostingBudget :: M ResourceBudget
hostingBudget =
  ResourceBudget <$> view #hostingVcpuBudget <*> view #hostingMemBudgetMiB
```

(Import `ResourceBudget` from `Garnix.Hosting.ServerPool.Types`.)

- [ ] **Step 3:** In `Garnix.hs`, after the `serverPool` parse (line ~351), add:

```haskell
  memBudgetSpec <- (>>= parseBudget . cs) <$> lookupEnv "GARNIX_HOSTING_MEM_BUDGET"
  cpuBudgetSpec <- (>>= parseBudget . cs) <$> lookupEnv "GARNIX_HOSTING_CPU_BUDGET"
  totalMiB <- hostTotalMiB
  totalVcpus <- hostVcpus
  let hostingMemBudgetMiB' = resolveBudget totalMiB memBudgetSpec
      hostingVcpuBudget' = resolveBudget totalVcpus cpuBudgetSpec
```

Then set the two new `Env` fields (near line 446 `serverPoolConfig = serverPool,`):

```haskell
              serverPoolConfig = serverPool,
              hostingMemBudgetMiB = hostingMemBudgetMiB',
              hostingVcpuBudget = hostingVcpuBudget',
```

Add imports for `parseBudget`, `resolveBudget`, `hostTotalMiB`, `hostVcpus`.

- [ ] **Step 4:** Fix every other `Env {..}` construction site — grep `Env\b.*{` across `backend/` (notably `TestHelpers`/`withServer`) and add the two fields (default both to `Nothing`, keeping tests unbounded). Compile to find them all.

- [ ] **Step 5: Run to verify pass** — `nix build .#backend_garnixHaskellPackage 2>&1`. Expected: PASS (no behavior change yet; budgets parsed but unused).

- [ ] **Step 6: Commit**

```bash
git add backend/src/Garnix/Monad.hs backend/src/Garnix.hs backend/test/
git commit -m "hosting: read + resolve RAM/vCPU budgets into Env (unused wiring)"
```

---

### Task 4: Committed-resources accounting + eviction query

**Files:**
- Modify: `backend/src/Garnix/DB.hs`
- Test: extend `ServerPoolSpec` (Task 5) — this task ships the DB fns; Task 5 exercises them via the pool.

**Interfaces:**
- Consumes: `Committed`, `sumTierResources` (Task 1).
- Produces:
  - `committedResources :: M Committed` — sum of `tierResources` over active `servers` (`ended_at IS NULL`) **plus every** `server_pool` row (ready + in-flight), so a budget check counts all RAM/CPU the host has actually committed.
  - `claimIdleReadyPoolVMForEviction :: M (Maybe PreprovisionedServer)` — atomically `DELETE` one **ready** pool row (any tier), returning it so the caller can destroy the guest; returns `Nothing` if the pool has no ready idle VM. (Prefer evicting the *oldest* `ready_at` — least likely to be about to be claimed.)

- [ ] **Step 1: Write failing test** (in `ServerPoolSpec.hs`, DB-level):

```haskell
  it "committedResources sums active servers and pool rows" $ do
    -- seed: one active i2x4 server + one ready i1x1 pool row (helpers per existing specs)
    seedActiveServer I2x4
    seedReadyPoolRow I1x1
    committed <- committedResources
    committed `shouldBe` Committed {committedVcpus = 2 + 1, committedMiB = 4096 + 1024}
```

(Use the existing spec's server/pool seeding helpers; if none, insert via `newServerInPool` + a direct `servers` insert helper already present for other pool tests.)

- [ ] **Step 2: Run to verify failure** — build/run. Expected: FAIL (`committedResources` not in scope).

- [ ] **Step 3: Implement** in `DB.hs`:

```haskell
committedResources :: M Committed
committedResources = do
  rows <-
    pgQuery
      [pgSQL|
        SELECT server_tier, COUNT(*)::int8 FROM servers WHERE ended_at IS NULL
          GROUP BY server_tier
        UNION ALL
        SELECT server_tier, COUNT(*)::int8 FROM server_pool
          GROUP BY server_tier
      |]
  pure $ sumTierResources [(tier, fromIntegral n) | (tier, n) <- rows]

claimIdleReadyPoolVMForEviction :: M (Maybe PreprovisionedServer)
claimIdleReadyPoolVMForEviction =
  pgTransaction $ do
    evicted <-
      pgQuery
        [pgSQL|
          DELETE FROM server_pool
          WHERE id IN (
            SELECT id FROM server_pool
            WHERE ready_at IS NOT NULL
            ORDER BY ready_at ASC
            LIMIT 1
          )
          RETURNING id, provisioner_id, ipv4, ipv6, server_tier, ready_at
        |]
    pure $ case evicted of
      [] -> Nothing
      (row : _) -> Just (toPreprovisionedServer row)
```

(Reuse the existing `PreprovisionedServer` constructor/prism used by `claimServerDB`/`updatePreprovisionedServer`; match its exact column tuple. Confirm the `server_tier` decode via the existing `PGColumn "text" ServerTier` instance.)

- [ ] **Step 4: Run to verify pass** — build + run the new DB test. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/src/Garnix/DB.hs backend/test/
git commit -m "hosting: committedResources accounting + idle-ready-pool eviction query"
```

---

### Task 5: Budget-aware refill + on-demand/evict/wait in `createServer`

**Files:**
- Modify: `backend/src/Garnix/Hosting/ServerPool.hs`
- Test: `backend/test/spec/Garnix/Hosting/ServerPoolSpec.hs`

**Interfaces:**
- Consumes: `hostingBudget` (Task 3), `committedResources`, `claimIdleReadyPoolVMForEviction` (Task 4), `fitsBudget`/`ResourceBudget` (Task 1), existing `provisionServer`/`newServerInPool`/`setupServer`/`setPreprovisionedReady`/`deleteServer`.
- Produces:
  - `provisionOne :: ServerTier -> M ()` — factor the body of the refill loop's inner block (`newServerInPool` → `provisionServer` → `updatePreprovisionedServer` → `setupServer` → `setPreprovisionedReady`, with the existing `onError` guest-cleanup) into a reusable action.
  - Budget-gated refill: in `initializeProvisioningPool`, before `provisionOne`, check `fitsBudget budget committed tier`; skip warming a tier that would breach the budget.
  - On-demand path in `createServer.pollForServer`: on claim miss →
    1. if `fitsBudget budget committed tier`: `provisionOne tier` then loop (the fresh VM becomes claimable);
    2. else try `claimIdleReadyPoolVMForEviction`; if it returns a VM whose freed `(vcpu,mib)` makes room, `deleteServer` its guest and loop;
    3. else log a **wait reason** (`"createServer: waiting on RAM/vCPU budget (committed=… cap=…)"`) and `threadDelay`, then loop — **no** hard timeout while legitimately queued (see Step 6).

- [ ] **Step 1: Write failing tests** (`ServerPoolSpec.hs`, using the existing mocked provisioner — `waitTillServerIsInitializedMock` etc.):

```haskell
  it "provisions an unlisted tier on demand when under budget" $ do
    -- budget: plenty; pool empty; a createServer for I1x1 must provision one and return.
    withBudget (ResourceBudget (Just 8) (Just 16384)) $ do
      server <- createServer repoInfo branchDeploy (spinUp I1x1)
      server `shouldSatisfy` isJust  -- returned, not timed out

  it "does not keep-warm a tier that would exceed the budget" $ do
    withBudget (ResourceBudget (Just 1) (Just 1024)) $ do
      -- refill for an I2x4 target must skip (2 vcpu / 4096 MiB > cap)
      runRefillOnce
      getPreprovisionedServerCount I2x4 `shouldReturn` 0

  it "evicts an idle ready pool VM to make room for a needed tier" $ do
    withBudget (ResourceBudget (Just 2) (Just 4096)) $ do
      seedReadyPoolRow I2x4   -- fills the whole budget
      -- a createServer for I1x1 cannot fit until the idle I2x4 is evicted
      _ <- createServer repoInfo branchDeploy (spinUp I1x1)
      getPreprovisionedServerCount I2x4 `shouldReturn` 0  -- evicted
```

(Adapt to the spec's existing harness shape — `withServer`/mock provisioner. If `ServerPoolSpec.hs` doesn't exist yet, create it modeled on how `DeploySpec`/existing pool tests set up the mocked provisioner + DB.)

- [ ] **Step 2: Run to verify failure** — build/run. Expected: FAIL.

- [ ] **Step 3: Implement** — factor `provisionOne` and rewrite `createServer.pollForServer`:

```haskell
provisionOne :: ServerTier -> M ()
provisionOne serverTier = do
  id' <- DB.newServerInPool serverTier
  ( do
      server <- provisionServer id' serverTier <?> ("Preprovisioning server " <> show id')
      DB.updatePreprovisionedServer server
      (setupServer server >> DB.setPreprovisionedReady (server ^. id))
        `onError` bestEffortDeleteGuest (server ^. provisionedServerId)
    )
    `onError` DB.deleteServerFromPool id'
```

`createServer` claim-miss branch (replacing the bare wait at `ServerPool.hs:30-36`):

```haskell
          Nothing -> do
            budget <- hostingBudget
            committed <- DB.committedResources
            let tier = serverToSpinUp ^. #serverTier
            if fitsBudget budget committed tier
              then provisionOne tier >> pollForServer
              else
                DB.claimIdleReadyPoolVMForEviction >>= \case
                  Just victim -> do
                    log Informational $ "createServer: evicting idle pooled "
                      <> show (victim ^. #serverTier) <> " to free budget for " <> show tier
                    bestEffortDeleteGuest (victim ^. provisionedServerId)
                    pollForServer
                  Nothing -> do
                    log Informational $ "createServer: waiting on RAM/vCPU budget for "
                      <> show tier <> " (committed=" <> show committed <> " cap=" <> show budget <> ")"
                    threadDelay pollForServerDuration
                    pollForServer
```

Budget-gate the refill loop (`initializeProvisioningPool`): before `provisionOne`, read `budget`/`committed` and only warm while `fitsBudget budget committed serverTier` (re-check committed each iteration so concurrent warms don't overshoot).

- [ ] **Step 4:** Make `bestEffortDeleteGuest` top-level (it's currently in the `where` of `initializeProvisioningPool`) so `createServer` can call it.

- [ ] **Step 5: Run to verify pass** — build + run the ServerPool tests. Expected: PASS.

- [ ] **Step 6: Timeout policy** — the existing `serverWaitTimeout` (10 min, `ServerPool.hs:157`) must still fire for a *stuck provision* but not punish a *legitimately queued* deploy. Split: keep a bounded timeout around a single `provisionOne`/claim attempt, but when the reason is "waiting on budget" (branch 3) reset/skip the deadline and rely on periodic logging. Add a test: a deploy queued behind a full budget stays Pending past 10 min (no `ProvisioningError`) until room frees. Then commit.

```bash
git add backend/src/Garnix/Hosting/ServerPool.hs backend/test/
git commit -m "hosting: elastic on-demand provisioning with budget gate, eviction, and queue-wait"
```

---

### Task 6: NixOS module options + env rendering

**Files:**
- Modify: `backend/nixos-module.nix` (options near the existing `serverPool` at `424`; env near `752` `GARNIX_SERVER_POOL=…`)

**Interfaces:**
- Produces env: `GARNIX_HOSTING_MEM_BUDGET=total:<MiB>|reserve:<MiB>`, `GARNIX_HOSTING_CPU_BUDGET=total:<n>|reserve:<n>` (omitted when unset).

- [ ] **Step 1:** Add options (submodule per dimension; exactly one of the two attrs set):

```nix
hosting.memoryBudget = lib.mkOption {
  default = null;
  description = ''
    Ceiling on TOTAL RAM across all hosted guests (active + warm pool +
    in-flight). Set exactly one of totalGiB (absolute cap) or reserveGiB
    (leave this many GiB free for the rest of the host). Unset = unbounded.
  '';
  type = lib.types.nullOr (lib.types.submodule {
    options = {
      totalGiB = lib.mkOption { type = lib.types.nullOr lib.types.ints.unsigned; default = null; };
      reserveGiB = lib.mkOption { type = lib.types.nullOr lib.types.ints.unsigned; default = null; };
    };
  });
};
hosting.cpuBudget = lib.mkOption {
  default = null;
  description = ''
    Ceiling on TOTAL vCPUs across all hosted guests. Set exactly one of
    totalVcpus (absolute) or reserveCores (leave this many host cores free).
    Unset = unbounded.
  '';
  type = lib.types.nullOr (lib.types.submodule {
    options = {
      totalVcpus = lib.mkOption { type = lib.types.nullOr lib.types.ints.unsigned; default = null; };
      reserveCores = lib.mkOption { type = lib.types.nullOr lib.types.ints.unsigned; default = null; };
    };
  });
};
```

- [ ] **Step 2:** Add `assertions` that at most one attr per dimension is set (fail eval with a clear message otherwise).

- [ ] **Step 3:** Render env in the `let` near `serverPoolEnv` and append to the service `Environment`:

```nix
memBudgetEnv =
  let b = config.services.garnixServer.hosting.memoryBudget;
  in if b == null then []
     else if b.totalGiB != null then [ "GARNIX_HOSTING_MEM_BUDGET=total:${toString (b.totalGiB * 1024)}" ]
     else if b.reserveGiB != null then [ "GARNIX_HOSTING_MEM_BUDGET=reserve:${toString (b.reserveGiB * 1024)}" ]
     else [];
cpuBudgetEnv =
  let b = config.services.garnixServer.hosting.cpuBudget;
  in if b == null then []
     else if b.totalVcpus != null then [ "GARNIX_HOSTING_CPU_BUDGET=total:${toString b.totalVcpus}" ]
     else if b.reserveCores != null then [ "GARNIX_HOSTING_CPU_BUDGET=reserve:${toString b.reserveCores}" ]
     else [];
```

Add `++ memBudgetEnv ++ cpuBudgetEnv` to the service's `Environment` list (where `GARNIX_SERVER_POOL=…` is added).

- [ ] **Step 4: Verify** the module evaluates: `nix eval .#nixosConfigurations.<a-test-host>.config.systemd.services.garnixServer.serviceConfig` or a fixture in `examples/`. Expected: exit 0, env contains the budget vars when set.

- [ ] **Step 5: Commit**

```bash
git add backend/nixos-module.nix
git commit -m "nixos-module: hosting.memoryBudget / hosting.cpuBudget (absolute or reserve)"
```

---

### Task 7: Erdtree config + docs + rollback of the stopgap

**Files:**
- Modify: `~/dotfiles/modules/hosts/erdtree/garnix.nix`
- Modify: `docs/` hosting docs and/or the `using-garnix-ci` skill

- [ ] **Step 1:** On erdtree, set a real budget and drop the now-unnecessary hand-tuned static pool (or keep a tiny keep-warm target):

```nix
# Elastic provisioning bounded by RAM/CPU; guests are provisioned on demand
# for whatever tier a deploy asks for, up to these ceilings.
hosting.memoryBudget = { reserveGiB = 80; };   # always leave 80 GiB for the gaming/HPC workloads
hosting.cpuBudget    = { reserveCores = 4; };   # leave 4 host cores free
serverPool = { i2x4 = 1; };                     # optional keep-warm target, clamped to the budget
```

- [ ] **Step 2:** Revert the garnix-hello stopgap decision: with on-demand provisioning, `hello-authed` no longer *needs* `machine = "i2x4"` — but keep it anyway for the i1x1-ENOMEM reason documented in Task-0 notes; leave a comment that the tier is chosen for ENOMEM headroom, not pool availability.

- [ ] **Step 3:** Document the two options + reserve-vs-absolute semantics + the "provisions on demand up to the budget, queues when full" behavior in the hosting docs and the `using-garnix-ci` skill's operating section.

- [ ] **Step 4:** Deploy (`just build-to-erdtree`) — restarts `garnixServer`; do it when no long build is in flight. Confirm via logs that budget resolution logged the absolute caps at startup, and a fresh multi-server deploy provisions on demand.

- [ ] **Step 5: Commit** (dotfiles + fork docs separately).

---

## Follow-ups (out of scope here, but enabled by this work)

- **Surface the wait reason in the UI** (the "Waiting on" tree): emit the `createServer` budget-wait / on-demand-provisioning state as a `WaitNode` child of the deployment run (via the `BuildWaitTracker`), so a queued deploy shows "waiting on RAM budget / booting a fresh i2x4" instead of a silent Pending. This directly addresses the earlier request that the deployment row expand with "waiting on server to boot".
- **Metrics:** export committed vs. budget (RAM/vCPU) as gauges for the Monitor page.

## Self-Review

- **Coverage:** on-demand (Task 5) ✓, keep-warm within budget (Task 5) ✓, RAM+CPU dual budget (Tasks 1–3) ✓, absolute+reserve (Tasks 2,6) ✓, evict-then-queue (Task 5) ✓, config (Tasks 3,6,7) ✓.
- **Type consistency:** `Committed`/`ResourceBudget`/`fitsBudget` names identical across Tasks 1/3/5; memory is MiB end-to-end (nix multiplies GiB→MiB at render; `tierResources` is MiB).
- **Placeholder scan:** all steps carry real code/SQL/nix; DB tuple decode + spec-harness shapes are the two spots the implementer confirms against existing patterns (`claimServerDB`, existing pool specs) — noted inline.
