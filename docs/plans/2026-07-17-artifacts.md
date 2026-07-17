# Build Artifacts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish declared nix build outputs as downloadable, retained, lockable artifacts in two B2 buckets, served through garnix with stable latest-URLs — replacing GitHub Actions artifacts (spec: `docs/plans/2026-07-17-artifacts-design.md`).

**Architecture:** A `garnix.yaml` `artifacts:` section auto-includes packages in builds; after each successful build a publisher walks the output, uploads content-addressed objects (per-file + `all.zip` + `manifest.json`) through an `ArtifactStore` record-of-functions in `Env` (amazonka impl in prod, in-memory in tests); DB rows link builds to content; a reaper enforces retention/lock/keep-latest and GCs unreferenced objects; a Servant sub-API serves 302 downloads (presigned for private) and lock management; the Configure page gets retention settings.

**Tech Stack:** Haskell/Servant + postgresql-typed + amazonka + crypton + zip-archive (new dep); sqitch; Next.js/zod frontend; NixOS module; agenix secrets (already provisioned).

## Global Constraints

- Repo: `~/Development/garnix-ci`, branch `main`. Commit per task; push only when the plan says.
- Backend gate (fast, run after every backend task): find the dev pg socket dir `ls -d /tmp/garnix-specs.*/pg-tmp/test` (pick the one whose `.s.PGSQL.9178` socket exists; call it `$PG`), then:
  `cd ~/Development/garnix-ci && nix develop -c bash -c "export TPG_HOST=$PG TPG_SOCK=$PG/.s.PGSQL.9178 TPG_PORT=9178 TPG_USER=garnix TPG_PASS=garnix TPG_DB=garnix; cd backend && cabal build lib:garnix"` — poll ~15s. `-Wall -Werror`: no unused imports; prefix unused args with `_`. Same env for `cabal build test:spec` / `cabal run test:spec -- --match "..."`.
- The `M` monad has NO MonadFail: never `[x] <- ...`; use `case`.
- makeFields lenses must be exported/used or GHC errors (`-Wunused-top-binds`).
- hlint must stay clean: `nix develop -c bash -c 'cd backend && hlint src'` → "No hints". Frontend knip must stay clean (no unused exports/files).
- sqitch migrations are deploy-only: `sql/deploy/<name>.sql` + a `sqitch.plan` line; apply manually to the dev pg before compiling code that references new columns.
- Frontend gate: `nix build ~/Development/garnix-ci#frontend_default --no-link` (exit 0).
- NO deploy to erdtree — user-gated. Dotfiles/agent-skills changes are committed but deploys are left to the operator.
- Secrets: never commit key material; the four `garnix-s3-artifacts-*.age` files already exist in `~/dotfiles-secrets`; bucket names come from `garnixData.b2.artifacts{PublicBucket,PrivateBucket,PublicBaseUrl}`.
- Exact values from the spec: default retention **30 days**, keep-latest default **false**, presign TTL **10 minutes**, reaper interval **1 hour**, failed-row prune age **7 days**, artifact name regex `[a-zA-Z0-9._-]+`, buckets stored as text `'public'`/`'private'`.

---

### Task 1: `garnix.yaml` `artifacts:` section

**Files:**
- Modify: `backend/src/Garnix/YamlConfig.hs`
- Test: `backend/test/spec/Garnix/YamlConfigSpec.hs`

**Interfaces:**
- Produces: `data ArtifactSection = ArtifactSection { _artifactSectionPackage :: PackageName, _artifactSectionName :: Maybe Text }` with makeFields lenses (`package`, `name`); `GarnixConfig` gains `_garnixConfigArtifacts :: [ArtifactSection]` (lens `artifacts`, codec default `[]`); `artifactDisplayName :: ArtifactSection -> Text`.

- [ ] **Step 1: Write the failing test** — in `YamlConfigSpec.hs`, next to the servers-section tests:

```haskell
    it "parses the artifacts section" $ do
      let yaml = "artifacts:\n  - package: web-skills-zips\n    name: claude-skills\n"
      config <- parseGarnixConfig yaml  -- use the spec's existing parse helper name
      (config ^. artifacts)
        `shouldBe` [ArtifactSection {_artifactSectionPackage = "web-skills-zips", _artifactSectionName = Just "claude-skills"}]

    it "artifact name defaults to the package" $ do
      artifactDisplayName (ArtifactSection "some-pkg" Nothing) `shouldBe` "some-pkg"
```

(Mirror the exact parse-helper used by neighboring tests in that file — it may be `decodeEither'`-based; copy the pattern.)

- [ ] **Step 2: Run to verify it fails** — `cabal build test:spec` fails with `Not in scope: artifacts` / `ArtifactSection`.

- [ ] **Step 3: Implement** — in `YamlConfig.hs`:

```haskell
data ArtifactSection = ArtifactSection
  { _artifactSectionPackage :: PackageName,
    _artifactSectionName :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)

instance HasCodec ArtifactSection where
  codec =
    object "artifacts"
      $ ArtifactSection
      <$> requiredField "package" "The flake package whose build output is published as a downloadable artifact. Automatically included in builds."
      .= _artifactSectionPackage
      <*> optionalField "name" "The artifact's display/URL name ([a-zA-Z0-9._-]+). Defaults to the package name."
      .= _artifactSectionName

artifactDisplayName :: ArtifactSection -> Text
artifactDisplayName s = fromMaybe (getPackageName (_artifactSectionPackage s)) (_artifactSectionName s)
```

Add to `GarnixConfig`: field `_garnixConfigArtifacts :: [ArtifactSection]` with codec line (place next to the servers field):

```haskell
      <*> optionalFieldWithDefault "artifacts" [] "Build outputs to publish as downloadable artifacts."
      .= _garnixConfigArtifacts
```

Run `makeFields ''ArtifactSection` next to the other makeFields calls; export `ArtifactSection (..)`, `artifactDisplayName`, and the new lenses (`artifacts` comes from the GarnixConfig makeFields). If `package`/`name` lens names collide with `Garnix.Types` exports in consumers, extend the existing `hiding` lists the way `exposeSSH` was handled. (`getPackageName` — check the accessor name on `PackageName` in `Garnix.Types`; if it's a different unwrapper, use that.)

- [ ] **Step 4: Golden schema** — `cabal run test:spec -- --match "ConfigSchema"` will fail on the schema golden; inspect the diff (it must only add the `artifacts` section), then accept it by replacing the golden file with the generated `.actual` (hspec-golden convention — the failure message names both paths).

- [ ] **Step 5: Run the two new tests + full YamlConfigSpec** — `cabal run test:spec -- --match "YamlConfig"` → PASS.

- [ ] **Step 6: Commit** — `git add backend/src/Garnix/YamlConfig.hs backend/test/spec/Garnix/YamlConfigSpec.hs <golden file> && git commit -m "feat(artifacts): garnix.yaml artifacts section"`

---

### Task 2: Database migration

**Files:**
- Create: `sql/deploy/add-artifacts.sql`
- Modify: `sql/sqitch.plan`

**Interfaces:**
- Produces: tables `artifacts`, `artifact_objects`; columns `server_settings.artifact_retention_days`, `server_settings.artifact_keep_latest`, `repo_config.artifact_retention_days`, `repo_config.artifact_keep_latest` — exactly as below; later tasks' SQL depends on these names.

- [ ] **Step 1: Write the migration** — `sql/deploy/add-artifacts.sql`:

```sql
-- Deploy garnix:add-artifacts to pg

BEGIN;

CREATE TABLE artifact_objects (
  store_hash text NOT NULL,
  bucket     text NOT NULL,
  total_size bigint NOT NULL,
  file_count int NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_hash, bucket)
);

CREATE TABLE artifacts (
  id          bigserial PRIMARY KEY,
  build_id    bigint NOT NULL REFERENCES builds(id),
  repo_user   text NOT NULL,
  repo_name   text NOT NULL,
  branch      text,
  name        text NOT NULL,
  store_hash  text NOT NULL,
  bucket      text NOT NULL,
  status      text NOT NULL,
  locked      boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (build_id, name)
);
CREATE INDEX artifacts_repo_branch_name_idx ON artifacts (repo_user, repo_name, branch, name, created_at DESC);

ALTER TABLE server_settings
  ADD COLUMN artifact_retention_days int NOT NULL DEFAULT 30,
  ADD COLUMN artifact_keep_latest boolean NOT NULL DEFAULT false;

ALTER TABLE repo_config
  ADD COLUMN artifact_retention_days int,
  ADD COLUMN artifact_keep_latest boolean;

COMMIT;
```

- [ ] **Step 2: Plan line** — append to `sql/sqitch.plan` (follow the existing line format exactly):

```
add-artifacts 2026-07-17T08:00:00Z joegoldin <joe@joegold.in> # Build artifacts: artifacts + artifact_objects tables, retention settings
```

- [ ] **Step 3: Apply to the dev pg** — `nix develop -c bash -c "psql -h $PG -p 9178 -U garnix -d garnix -f sql/deploy/add-artifacts.sql"` (PGPASSWORD=garnix). Verify: `\d artifacts` shows the table.

- [ ] **Step 4: Commit** — `git add sql/ && git commit -m "feat(artifacts): migration for artifacts tables + retention settings"`

---

### Task 3: `ArtifactStore` in Env + amazonka implementation

**Files:**
- Modify: `backend/src/Garnix/Monad.hs` (Env field + record type)
- Create: `backend/src/Garnix/Artifacts/Store.hs`
- Modify: `backend/src/Garnix.hs` (env-var construction), `backend/garnix.cabal` (exposed-modules + `zip-archive` dep), `backend/test/spec/Garnix/TestHelpers/Monad.hs` (Env fixture)

**Interfaces:**
- Produces (in `Garnix.Monad`):

```haskell
data ArtifactBucket = ArtifactPublic | ArtifactPrivate deriving (Eq, Show, Generic)

artifactBucketText :: ArtifactBucket -> Text          -- "public" / "private"
artifactBucketFromText :: Text -> Maybe ArtifactBucket

data ArtifactStore = ArtifactStore
  { _artifactStorePutFile      :: ArtifactBucket -> Text -> FilePath -> M (),
    _artifactStorePutBytes     :: ArtifactBucket -> Text -> BSL.ByteString -> M (),
    _artifactStoreDeletePrefix :: ArtifactBucket -> Text -> M (),
    _artifactStorePresignGet   :: ArtifactBucket -> Text -> M Text,
    _artifactStorePublicUrl    :: Text -> Text
  } deriving (Generic)
```
  plus Env field `artifactStore :: Maybe ArtifactStore`.
- Produces (in `Garnix.Artifacts.Store`): `s3ArtifactStore :: Amazonka.Env -> Amazonka.Env -> Amazonka.BucketName -> Amazonka.BucketName -> Text -> ArtifactStore` (public env, private env, public bucket, private bucket, public base URL).

- [ ] **Step 1: Types in Monad.hs** — add the block above near `S3CacheEnv`; `artifactBucketText ArtifactPublic = "public"` etc. Add `artifactStore :: Maybe ArtifactStore` to `Env` (near `s3CacheEnv`). This breaks every `Env{..}` construction — fix `Garnix.hs` (Step 2) and the test Env (Step 4).

- [ ] **Step 2: Env construction in Garnix.hs** — next to the `S3CacheEnv` construction (lines ~145–210), read (reusing the file's existing `readOptionalSecret` helper and the amazonka-env builder used for the cache — same `S3_CACHE_HOST`/`S3_CACHE_REGION` service override):

```haskell
  -- Build artifacts (optional feature): both buckets must be configured.
  artifactsPublicBucket <- lookupEnv "S3_ARTIFACTS_PUBLIC_BUCKET"
  artifactsPrivateBucket <- lookupEnv "S3_ARTIFACTS_PRIVATE_BUCKET"
  artifactsPublicBaseUrl <- lookupEnv "S3_ARTIFACTS_PUBLIC_BASE_URL"
  artifactStore <- case (artifactsPublicBucket, artifactsPrivateBucket, artifactsPublicBaseUrl) of
    (Just pub, Just priv, Just baseUrl) -> do
      pubKeyId <- readOptionalSecret "S3_ARTIFACTS_PUBLIC_ACCESS_KEY_ID" "/run/secrets/s3-artifacts-public-access-key-id"
      pubKey <- readOptionalSecret "S3_ARTIFACTS_PUBLIC_SECRET_ACCESS_KEY" "/run/secrets/s3-artifacts-public-secret-access-key"
      privKeyId <- readOptionalSecret "S3_ARTIFACTS_PRIVATE_ACCESS_KEY_ID" "/run/secrets/s3-artifacts-private-access-key-id"
      privKey <- readOptionalSecret "S3_ARTIFACTS_PRIVATE_SECRET_ACCESS_KEY" "/run/secrets/s3-artifacts-private-secret-access-key"
      case (pubKeyId, pubKey, privKeyId, privKey) of
        (Just a, Just b, Just c, Just d) -> do
          pubEnv <- mkAmazonkaEnv a b      -- the same helper the cache env uses
          privEnv <- mkAmazonkaEnv c d
          pure $ Just $ s3ArtifactStore pubEnv privEnv
            (Amazonka.BucketName (cs pub)) (Amazonka.BucketName (cs priv)) (cs baseUrl)
        _ -> error "S3_ARTIFACTS_* buckets are set but their key pairs are missing."
    _ -> pure Nothing
```

Thread `artifactStore` into the `Env{..}` record. (If `mkAmazonkaEnv` is a local `where`/let binding scoped to the cache block, lift it to a top-level helper first.)

- [ ] **Step 3: `Garnix.Artifacts.Store`** — the amazonka impl. Follow `Garnix.S3Cache.upload`'s PutObject usage and `Garnix.API.Cache`'s presign (`Amazonka.presignURL env now (toAmazonkaSeconds ttl) (Amazonka.newGetObject bucket (Amazonka.ObjectKey key))`):

```haskell
module Garnix.Artifacts.Store (s3ArtifactStore) where
-- putFile: Amazonka.send env (Amazonka.newPutObject bucket (ObjectKey key) (Amazonka.Hashed <$> Amazonka.hashedFile path))
-- putBytes: newPutObject with Amazonka.toBody bytes
-- deletePrefix: paginate Amazonka.newListObjectsV2 (prefix) and send newDeleteObject per key
-- presignGet: 10-minute TTL (fromMinutes @Int 10)
-- publicUrl key = baseUrl <> "/" <> key
```

Write it fully (each field a small function choosing env/bucket by `ArtifactBucket`). Add `Garnix.Artifacts.Store` to `library.exposed-modules` in `garnix.cabal` and `zip-archive` to the library `build-depends` (used in Task 5; adding now keeps one cabal edit).

- [ ] **Step 4: Test Env** — in `TestHelpers/Monad.hs`'s Env literal add `artifactStore = Nothing,`.

- [ ] **Step 5: Compile gate** — `cabal build lib:garnix` then `cabal build test:spec` → both clean. `hlint src` → No hints.

- [ ] **Step 6: Commit** — `git commit -m "feat(artifacts): ArtifactStore env + amazonka S3 implementation"`

---

### Task 4: DB layer (`Garnix.DB.Artifacts`)

**Files:**
- Create: `backend/src/Garnix/DB/Artifacts.hs` (add to cabal exposed-modules)
- Test: `backend/test/spec/Garnix/DB/ArtifactsSpec.hs` (add to test-suite other-modules + follow `Spec.hs`/hspec-discover convention of the other DB specs)

**Interfaces:**
- Produces:

```haskell
data ArtifactRow = ArtifactRow
  { _artifactRowId :: Int64, _artifactRowBuildId :: BuildId,
    _artifactRowRepoUser :: GhRepoOwner, _artifactRowRepoName :: GhRepoName,
    _artifactRowBranch :: Maybe Branch, _artifactRowName :: Text,
    _artifactRowStoreHash :: Text, _artifactRowBucket :: ArtifactBucket,
    _artifactRowStatus :: Text, _artifactRowLocked :: Bool,
    _artifactRowCreatedAt :: UTCTime }

upsertArtifact :: Build -> Text -> Text -> ArtifactBucket -> Text -> M ()   -- name, storeHash, bucket, status
getArtifactsForBuild :: BuildId -> M [ArtifactRow]
getArtifactsForRepo :: GhRepoOwner -> GhRepoName -> Maybe Branch -> M [ArtifactRow]
getLatestArtifact :: GhRepoOwner -> GhRepoName -> Branch -> Text -> M (Maybe ArtifactRow)
getArtifactByBuildAndName :: BuildId -> Text -> M (Maybe ArtifactRow)
setBuildArtifactsLocked :: BuildId -> Bool -> M ()
deleteArtifactRow :: Int64 -> M ()
artifactObjectExists :: Text -> ArtifactBucket -> M Bool
insertArtifactObject :: Text -> ArtifactBucket -> Int64 -> Int -> M ()
```

- [ ] **Step 1: Failing tests** — `ArtifactsSpec.hs` using the standard `inM $ beforeM_ truncateDBM` shell (copy from `DBSpec.hs`) plus truncating `artifacts, artifact_objects`:

```haskell
    it "upserts and fetches an artifact row" $ do
      build <- testBuild $ (repoUser .~ "o") . (repoName .~ "r") . (branch ?~ "main") . (package .~ "pkg")
      DB.upsertArtifact build "claude-skills" "hash1" ArtifactPublic "published"
      rows <- DB.getArtifactsForBuild (build ^. id)
      map _artifactRowName rows `shouldBeM` ["claude-skills"]
      -- upsert overwrites, not duplicates:
      DB.upsertArtifact build "claude-skills" "hash2" ArtifactPublic "published"
      rows2 <- DB.getArtifactsForBuild (build ^. id)
      map _artifactRowStoreHash rows2 `shouldBeM` ["hash2"]

    it "latest returns the newest published row per branch+name" $ do
      b1 <- testBuild $ (repoUser .~ "o") . (repoName .~ "r") . (branch ?~ "main")
      b2 <- testBuild $ (repoUser .~ "o") . (repoName .~ "r") . (branch ?~ "main")
      DB.upsertArtifact b1 "a" "h1" ArtifactPublic "published"
      DB.upsertArtifact b2 "a" "h2" ArtifactPublic "published"
      row <- DB.getLatestArtifact "o" "r" "main" "a"
      (_artifactRowStoreHash <$> row) `shouldBeM` Just "h2"

    it "locking flips all of a build's rows" $ do
      b <- testBuild identity
      DB.upsertArtifact b "a" "h" ArtifactPrivate "published"
      DB.setBuildArtifactsLocked (b ^. id) True
      rows <- DB.getArtifactsForBuild (b ^. id)
      map _artifactRowLocked rows `shouldBeM` [True]

    it "object dedupe bookkeeping" $ do
      DB.artifactObjectExists "h" ArtifactPublic `shouldReturnM` False
      DB.insertArtifactObject "h" ArtifactPublic 123 4
      DB.artifactObjectExists "h" ArtifactPublic `shouldReturnM` True
```

- [ ] **Step 2: Run** → fails (module missing).

- [ ] **Step 3: Implement** — `pgSQL` queries. `upsertArtifact` reads repo/branch off the `Build` (`build ^. repoUser` etc.) and uses `INSERT ... ON CONFLICT (build_id, name) DO UPDATE SET store_hash=EXCLUDED.store_hash, bucket=EXCLUDED.bucket, status=EXCLUDED.status, created_at=now()`. `getLatestArtifact` = `... WHERE status='published' AND repo_user=... AND branch=... AND name=... ORDER BY created_at DESC, id DESC LIMIT 1`. Bucket column marshals via `artifactBucketText`/`artifactBucketFromText` (unknown text → `throw $ OtherError ...`, no MonadFail). For build-id SQL params, follow the exact pattern existing `DB.hs` queries use for `builds.id` (BuildId has PG instances via its HashId newtype).

- [ ] **Step 4: Run tests** — `cabal run test:spec -- --match "Garnix.DB.Artifacts"` → PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat(artifacts): DB layer"`

---

### Task 5: Publish pipeline + build hook + auto-include

**Files:**
- Create: `backend/src/Garnix/Artifacts.hs` (cabal exposed-modules)
- Modify: `backend/src/Garnix/Build/Flake.hs` (hook + auto-include)
- Test: `backend/test/spec/Garnix/ArtifactsSpec.hs` (test-suite other-modules)

**Interfaces:**
- Consumes: Task 1 `ArtifactSection`/`artifactDisplayName`/`artifacts` lens; Task 3 `ArtifactStore`; Task 4 DB fns; `withStorePath :: Build -> Text -> (Maybe Nix.StorePath -> M a) -> M a` (`Garnix.Nix.StorePath`); `DB.getRepoConfig` + `privateCache` lens (bucket rule, same as `S3Cache.upload`).
- Produces:

```haskell
data ManifestFile = ManifestFile { path :: Text, size :: Int64, sha256 :: Text, executable :: Bool }
data ArtifactManifest = ArtifactManifest { files :: [ManifestFile], totalSize :: Int64, fileCount :: Int, storeHash :: Text }
-- ToJSON for both (snake_case field names via the codebase's ourToJSON options)
walkOutput :: FilePath -> IO (Either Text [(FilePath, FilePath, Int64, Bool)])  -- (relPath, resolvedAbsPath, size, executable)
publishArtifacts :: GarnixConfig -> [Build] -> M ()
```

- [ ] **Step 1: Failing tests** (`ArtifactsSpec.hs`) — pure parts first:

```haskell
  describe "walkOutput" $ do
    it "walks files, dereferences symlinks, records exec bits" $ do
      withSystemTempDirectory "artifact" $ \dir -> do
        writeFile (dir </> "a.txt") "hello"
        createDirectoryIfMissing True (dir </> "sub")
        writeFile (dir </> "sub/b.sh") "#!/bin/sh"
        p <- getPermissions (dir </> "sub/b.sh")
        setPermissions (dir </> "sub/b.sh") (setOwnerExecutable True p)
        createFileLink (dir </> "a.txt") (dir </> "link.txt")
        Right entries <- walkOutput dir
        sort (map (\(rel, _, _, _) -> rel) entries) `shouldBe` ["a.txt", "link.txt", "sub/b.sh"]
        lookup "sub/b.sh" (map (\(rel, _, _, x) -> (rel, x)) entries) `shouldBe` Just True

    it "fails on dangling symlinks" $ do
      withSystemTempDirectory "artifact" $ \dir -> do
        createFileLink (dir </> "missing") (dir </> "dangling")
        result <- walkOutput dir
        result `shouldSatisfy` isLeft
```

Then the pipeline with an in-memory store (IORef of `Map (ArtifactBucket, Text) Int64` recording uploaded keys+sizes) and a fixture build whose `outputs` point at a temp dir registered as the store path — build the store-path plumbing the way `Action.hs`'s specs fake outputs (see `FodCheckSpec`/`BuildSpec` fixtures that set `outputs` on `testBuild`); assert: (1) publish of a successful matching build uploads `files/a.txt`, `all.zip`, `manifest.json` under `artifacts/<hash>/` and upserts a `published` row; (2) a second publish with the same hash uploads **nothing new** (dedupe) but still upserts the row; (3) a failing walk (dangling symlink) upserts a `failed` row and does not throw.

- [ ] **Step 2: Run** → fails.

- [ ] **Step 3: Implement `Garnix.Artifacts`:**

```haskell
publishArtifacts :: GarnixConfig -> [Build] -> M ()
publishArtifacts config builds =
  view #artifactStore >>= \case
    Nothing -> pure ()
    Just store -> forM_ (config ^. artifacts) $ \section -> do
      let wanted b = (b ^. package) == getPackageName (section ^. package)
                       && (b ^. status) == Just Success
      forM_ (filter wanted builds) $ \build ->
        publishOne store section build `catchAny` \e -> do
          log Warning $ "artifact publish failed: " <> show e
          DB.upsertArtifact build (artifactDisplayName section) "" (bucketFor build) "failed"
```

`publishOne`: first validate the name — `T.all (\c -> isAlphaNum c || c `elem` ("._-" :: String)) name && not (T.null name)` — an invalid name throws (→ caught → `failed` row); then `withStorePath build "out"` → `Nothing` = throw; `Just sp` → `storeHash = getHash sp`; bucket via `bucketFor` (fetch `DB.getRepoConfig`, `usePrivateBucket = not (isRepoPublic (build ^. repoIsPublic)) || repoConfig ^. privateCache` — identical to `S3Cache.upload`); dedupe: `unlessM (DB.artifactObjectExists storeHash bucket) $ do { entries <- walk...; upload each file to "artifacts/<hash>/files/<rel>"; build zip in a temp dir with zip-archive (set entry modes 0o755/0o644 via eExternalFileAttributes, epoch mtime for determinism); putFile "artifacts/<hash>/all.zip"; putBytes manifest "artifacts/<hash>/manifest.json"; DB.insertArtifactObject ... }`; finally `DB.upsertArtifact build name storeHash bucket "published"`. sha256 with `Crypto.Hash (hashWith SHA256)` over strict file bytes (crypton, already a dep). `walkOutput`: recursive `listDirectory`, `pathIsSymbolicLink` → `canonicalizePath` + existence check (Left on dangling), `getPermissions` for exec, `getFileSize`.

- [ ] **Step 4: Hook + auto-include in `Flake.hs`** — after `builds <- joinAll buildPromises >>= resolve` (before the `allBuildsSucceeded` binding) add `Artifacts.publishArtifacts config builds`. In `setupBuilds`, extend the attribute list:

```haskell
  toBuild <- getAttributesToBuild commitInfo config
  let artifactAttr s = Attribute { _attributePackageType = TypePackage, _attributeSystem = Just X8664Linux, _attributePackageName = Just (s ^. package), _attributeExtension = Nothing }
      withArtifacts = toBuild <> filter (`notElem` toBuild) (map artifactAttr (config ^. artifacts))
```

and iterate `withArtifacts`. (Check `Attribute`'s actual field types in `Garnix.Attribute` — mirror `Action.hs`'s `getActionAppAttributes` construction exactly, with `TypePackage` instead of `TypeApp`.)

- [ ] **Step 5: Run tests + compile gate + hlint** — `--match "Garnix.Artifacts"` PASS; lib + test:spec build clean.

- [ ] **Step 6: Commit** — `git commit -m "feat(artifacts): publish pipeline, build hook, auto-include"`

---

### Task 6: Download + management API

**Files:**
- Create: `backend/src/Garnix/API/Artifacts.hs` (cabal exposed-modules)
- Modify: `backend/src/Garnix/API.hs` (mount)
- Test: `backend/test/spec/Garnix/API/ArtifactsSpec.hs`

**Interfaces:**
- Consumes: Task 4 DB fns; Task 3 store (`presignGet`, `publicUrl`); `Garnix.Access.hasAccessToRepo`; `Garnix.ParseHttpBasicAuth.parseBasicAuth` + the token-validation approach in `Garnix.API.Cache.Auth` (read it; reuse its user-lookup + `isAccessTokenValid` call shape, requiring the `api` scope).
- Produces: `ArtifactsAPI (..)`, `artifactsAPI :: AuthResult AuthJwtPayload -> Maybe Text -> ArtifactsAPI (AsServerT M)`; DTO `ArtifactDto { id, build_id, repo_user, repo_name, branch, name, store_hash, status, locked, created_at, total_size, file_count }` (sizes joined from `artifact_objects`).

- [ ] **Step 1: API record** (servant-generic, mirroring `ConfigureAPI`):

```haskell
data ArtifactsAPI route = ArtifactsAPI
  { _artifactsAPIListRepo   :: route :- "repo" :> Capture "owner" GhRepoOwner :> Capture "repo" GhRepoName :> QueryParam "branch" Branch :> Get '[JSON] [ArtifactDto],
    _artifactsAPIListBuild  :: route :- "build" :> Capture "buildId" BuildId :> Get '[JSON] [ArtifactDto],
    _artifactsAPIZipByBuild :: route :- "build" :> Capture "buildId" BuildId :> Capture "name" Text :> "all.zip" :> Get302,
    _artifactsAPIManifestByBuild :: route :- "build" :> Capture "buildId" BuildId :> Capture "name" Text :> "manifest" :> Get302,
    _artifactsAPIFileByBuild :: route :- "build" :> Capture "buildId" BuildId :> Capture "name" Text :> "files" :> CaptureAll "path" Text :> Get302,
    _artifactsAPIZipLatest  :: route :- Capture "owner" GhRepoOwner :> Capture "repo" GhRepoName :> Capture "branch" Branch :> Capture "name" Text :> "latest.zip" :> Get302,
    _artifactsAPIManifestLatest :: route :- Capture "owner" GhRepoOwner :> Capture "repo" GhRepoName :> Capture "branch" Branch :> Capture "name" Text :> "latest" :> "manifest" :> Get302,
    _artifactsAPIFileLatest :: route :- Capture "owner" GhRepoOwner :> Capture "repo" GhRepoName :> Capture "branch" Branch :> Capture "name" Text :> "latest" :> "files" :> CaptureAll "path" Text :> Get302,
    _artifactsAPILock   :: route :- "build" :> Capture "buildId" BuildId :> "lock" :> Post '[JSON] NoContent,
    _artifactsAPIUnlock :: route :- "build" :> Capture "buildId" BuildId :> "lock" :> Delete '[JSON] NoContent,
    _artifactsAPIDelete :: route :- Capture "artifactId" Int64 :> Delete '[JSON] NoContent
  } deriving Generic
```

`Get302` = the redirect response type; find how existing handlers redirect (search `err302` / `"Location"` in `src/Garnix/API/Auth.hs` and login handlers) and use the same alias/mechanism. Mount in `API.hs`:

```haskell
    artifacts :: r :- "api" :> "artifacts" :> Auth '[JWT, Cookie] AuthJwtPayload :> Header "authorization" Text :> ToServantApi ArtifactsAPI,
```

with the handler wired in the server record like `configure`.

- [ ] **Step 2: Access control helper** in `API/Artifacts.hs`:

```haskell
-- Public-bucket rows: anonymous OK. Private: session user with repo access,
-- or a basic-auth/Bearer access token (api scope) whose user has repo access.
-- Failure is a 404 (NoSuchBuild-style), not 403, to avoid existence leaks.
authorizeArtifact :: AuthResult AuthJwtPayload -> Maybe Text -> ArtifactRow -> M ()
```

Session path: resolve `User` the way other authed APIs do and call `hasAccessToRepo`. Token path: `parseBasicAuth` (or strip `Bearer `), validate with the same machinery `Garnix.API.Cache.Auth` uses, require the `api` scope, then `hasAccessToRepo`. Locks/delete additionally require admin (`subscriptionType == Just Admin` — same check the admin API uses).

- [ ] **Step 3: Handlers** — resolve row (`getArtifactByBuildAndName` / `getLatestArtifact`; missing → 404), `authorizeArtifact`, then redirect: `ArtifactPublic → publicUrl key`; `ArtifactPrivate → presignGet ArtifactPrivate key`. Keys: `"artifacts/" <> storeHash <> "/all.zip"`, `.../manifest.json`, `.../files/" <> T.intercalate "/" path` (reject `..` segments with a 400). DTO sizes come from a join in a new `Garnix.DB.Artifacts` query `getArtifactDtosForRepo/Build` (add it in this task, same file as Task 4).

- [ ] **Step 4: Tests** — dev-pg spec: latest resolution (two builds, newest wins), lock/unlock flips rows, non-admin lock → error, path traversal (`["..","x"]`) → error, private row + no auth → 404-shaped error. (Redirect handlers can be unit-tested by calling the handler functions directly and asserting the Location URL prefix.)

- [ ] **Step 5: Compile + tests + hlint; commit** — `git commit -m "feat(artifacts): download + management API"`

---

### Task 7: Retention reaper

**Files:**
- Create: `backend/src/Garnix/Artifacts/Reaper.hs` (cabal exposed-modules)
- Modify: `backend/src/Garnix.hs` (fork at startup), `backend/src/Garnix/DB/Artifacts.hs` (reap queries)
- Test: `backend/test/spec/Garnix/Artifacts/ReaperSpec.hs`

**Interfaces:**
- Produces: `initializeArtifactReaper :: M ThreadId` (forked in `Garnix.hs` when `artifactStore` is `Just`, next to the other startup forks — find where `initializeProvisioningPool` is started); `reapOnce :: M ()` (the testable body); DB: `reapExpiredArtifactRows :: M Int64`, `getOrphanedArtifactObjects :: M [(Text, ArtifactBucket)]`, `deleteArtifactObject :: Text -> ArtifactBucket -> M ()`.

- [ ] **Step 1: Failing tests** — dev-pg spec seeding rows with explicit `created_at` (add a test-only insert helper or `UPDATE artifacts SET created_at = now() - interval '40 days'` after upsert):

```haskell
    it "reaps expired unlocked rows, honors per-repo retention override" $ ...
    it "never reaps locked rows" $ ...
    it "keep-latest (global) protects the newest row per repo/branch/name" $ ...
    it "repo keep-latest override beats the global setting" $ ...
    it "prunes failed rows older than 7 days" $ ...
    it "GCs objects only when no row references them" $ ...   -- uses in-memory store; asserts deletePrefix called for orphan, not for referenced
```

- [ ] **Step 2: Run** → fails.

- [ ] **Step 3: Implement.** `reapExpiredArtifactRows` as one statement:

```sql
WITH s AS (SELECT artifact_retention_days AS d, artifact_keep_latest AS k FROM server_settings WHERE singleton),
eff AS (
  SELECT a.id,
         COALESCE(rc.artifact_retention_days, s.d) AS retention,
         COALESCE(rc.artifact_keep_latest, s.k) AS keep_latest,
         row_number() OVER (PARTITION BY a.repo_user, a.repo_name, a.branch, a.name ORDER BY a.created_at DESC, a.id DESC) AS rn
  FROM artifacts a
  CROSS JOIN s
  LEFT JOIN repo_config rc ON rc.repo_user = a.repo_user AND rc.repo_name = a.repo_name
  WHERE a.status = 'published' AND NOT a.locked
)
DELETE FROM artifacts a USING eff
WHERE a.id = eff.id
  AND a.created_at < now() - (eff.retention || ' days')::interval
  AND NOT (eff.keep_latest AND eff.rn = 1)
```

plus `DELETE FROM artifacts WHERE status='failed' AND created_at < now() - interval '7 days'`. `getOrphanedArtifactObjects`: `SELECT store_hash, bucket FROM artifact_objects ao WHERE NOT EXISTS (SELECT 1 FROM artifacts a WHERE a.store_hash=ao.store_hash AND a.bucket=ao.bucket)`. `reapOnce`: run deletes → for each orphan `deletePrefix bucket ("artifacts/" <> hash <> "/")` then `deleteArtifactObject`. `initializeArtifactReaper = NoThrow.forkForever (fromHours @Int 1) reapOnce` (mirror `initializeProvisioningPool`'s use of `NoThrow.forkForever`).

- [ ] **Step 4: Tests PASS; compile gate; hlint.**

- [ ] **Step 5: Commit** — `git commit -m "feat(artifacts): retention reaper with lock/keep-latest + object GC"`

---

### Task 8: Configure API extensions

**Files:**
- Modify: `backend/src/Garnix/API/Configure.hs`, `backend/src/Garnix/DB/Artifacts.hs` (settings queries)
- Test: extend `backend/test/spec/Garnix/API/ArtifactsSpec.hs` (or a ConfigureSpec if one exists — check; else the ArtifactsSpec)

**Interfaces:**
- Produces on `ConfigureSettingsDto` (new fields, keeping the JSON snake_case convention): `_configureSettingsDtoArtifactRetentionDays :: Int32`, `_configureSettingsDtoArtifactKeepLatest :: Bool`, `_configureSettingsDtoArtifactRepoOverrides :: [ArtifactRepoOverrideDto]` (`repo_user, repo_name, retention_days :: Maybe Int32, keep_latest :: Maybe Bool`), `_configureSettingsDtoArtifactUsage :: [ArtifactUsageDto]` (`repo_user, repo_name, total_size`), `_configureSettingsDtoLockedArtifactBuilds :: [LockedArtifactBuildDto]` (`build_id, repo_user, repo_name, branch, name, created_at`).
- New routes on `ConfigureAPI`: `PUT "artifacts" "default"` body `{retention_days :: Int32, keep_latest :: Bool}`; `PUT/DELETE "artifacts" "repo" :> Capture owner :> Capture repo` body `{retention_days :: Maybe Int32, keep_latest :: Maybe Bool}`.
- DB: `getArtifactSettings`, `setDefaultArtifactSettings :: Int32 -> Bool -> M ()` (singleton upsert like `default_build_timeout_minutes`), `setRepoArtifactSettings`/`deleteRepoArtifactSettings`, `getArtifactStorageUsage` (`SELECT repo_user, repo_name, SUM(DISTINCT-per-hash total_size)` — join rows to `artifact_objects`, `SUM` over `DISTINCT (store_hash,bucket)` per repo via a subquery), `getLockedArtifactBuilds`.

- [ ] **Step 1: Failing test** — settings roundtrip: set default 7/keep-latest true → `getArtifactSettings` reflects; repo override set/cleared; usage query returns deduped sums (two rows sharing a hash count once).
- [ ] **Step 2–3: Implement** — mirror the existing timeout endpoints exactly (admin gate included — copy the auth check `configureAPI` already applies).
- [ ] **Step 4: Tests + gates; commit** — `git commit -m "feat(artifacts): configure API for retention/keep-latest/usage/locks"`

---

### Task 9: Frontend — services + build-page Artifacts section

**Files:**
- Create: `frontend/src/services/artifacts.ts`
- Modify: `frontend/src/app/build/[slug]/page.tsx` (+ its `styles.module.css`)

**Interfaces:**
- Produces `services/artifacts.ts` (zod + `fetchFromAPI`, mirroring `services/servers.ts`):

```ts
export type Artifact = z.infer<typeof artifactSchema>;
const artifactSchema = z.object({
  id: z.number(), build_id: z.string(), repo_user: z.string(), repo_name: z.string(),
  branch: z.string().nullish().transform(v => v ?? null), name: z.string(),
  store_hash: z.string(), status: z.string(), locked: z.boolean(),
  created_at: z.coerce.date(), total_size: z.number(), file_count: z.number(),
});
export const getBuildArtifacts = (buildId: string) =>
  fetchFromAPI(z.array(artifactSchema), "GET", `artifacts/build/${buildId}`);
export const lockBuildArtifacts = (buildId: string) =>
  fetchFromAPI(z.unknown(), "POST", `artifacts/build/${buildId}/lock`);
export const unlockBuildArtifacts = (buildId: string) =>
  fetchFromAPI(z.unknown(), "DELETE", `artifacts/build/${buildId}/lock`);
export const artifactZipUrl = (buildId: string, name: string) =>
  `/api/artifacts/build/${buildId}/${encodeURIComponent(name)}/all.zip`;
export const artifactLatestZipUrl = (a: Artifact) =>
  a.branch ? `/api/artifacts/${a.repo_user}/${a.repo_name}/${encodeURIComponent(a.branch)}/${encodeURIComponent(a.name)}/latest.zip` : null;
```

(Match `build_id`'s actual JSON type to what the backend DTO emits — hashid string vs number — by checking how the build page's own service types build ids; adjust the schema accordingly. File listing uses the manifest endpoint: add `getArtifactManifest(buildId, name)` fetching `artifacts/build/<id>/<name>/manifest` — note it 302s to storage, so `fetch` follows the redirect and returns JSON; parse `{files: [{path, size, sha256, executable}], total_size, file_count, store_hash}`.)

- [ ] **Step 1: Implement service + an `ArtifactsSection` component** rendered near the logs section of `build/[slug]/page.tsx` (only when `artifacts.length > 0`): per artifact — name, size (human-formatted like the page's existing helpers), file count, Download `.zip` link, "latest" copy-URL button when `artifactLatestZipUrl` is non-null, lock toggle (only when the whoami user is admin — reuse however the page/nav detects admin), expandable file list from the manifest (name, size, download link `/files/<path>`, sha256 in a `title` tooltip). Failed rows render as a red "publish failed" chip.
- [ ] **Step 2: Gates** — `nix build .#frontend_default --no-link` exit 0; knip clean (`nix build .#checks.x86_64-linux.frontend_knip --no-link`) — every export above must be consumed.
- [ ] **Step 3: Commit** — `git commit -m "feat(artifacts): build-page artifacts section"`

---

### Task 10: Frontend — Configure page Artifacts card

**Files:**
- Modify: `frontend/src/app/configure/page.tsx` (+ styles), `frontend/src/services/configure.ts` (or wherever `setDefaultBuildTimeout` lives — same file)

**Interfaces:**
- Consumes Task 8's extended `GET /api/configure` DTO + new PUT/DELETE routes.
- Produces service fns: `setDefaultArtifactSettings(retentionDays: number, keepLatest: boolean)`, `setRepoArtifactSettings(owner, repo, retentionDays: number | null, keepLatest: boolean | null)`, `deleteRepoArtifactSettings(owner, repo)`; extended configure-settings zod schema with the Task 8 fields.

- [ ] **Step 1: Implement an `ArtifactSettings` component** as a sibling `styles.section` after `BuildTimeoutSettings`, mirroring its form/run patterns: global retention-days number input + keep-latest toggle; per-repo override table (add/edit/clear, same interaction as the timeout overrides); storage usage list (repo → human size, plus a total); locked builds table (repo, build link `/build/<id>`, created-at, Unlock button → `unlockBuildArtifacts`); a copyable latest-URL per distinct (repo, branch, name) derived from the locked/usage data — reuse the `CopyableCommand`-style copy button pattern from `app/servers/page.tsx`.
- [ ] **Step 2: Gates** — frontend build + knip clean.
- [ ] **Step 3: Commit** — `git commit -m "feat(artifacts): configure-page artifacts card"`

---

### Task 11: Nix wiring + Caddy bypass + docs

**Files:**
- Modify: `backend/nixos-module.nix`, `README.md`, and in **dotfiles**: `modules/hosts/erdtree/garnix.nix`; in **agent-skills**: `skills/using-garnix-ci/SKILL.md`

**Interfaces:**
- Consumes Task 3's env vars.

- [ ] **Step 1: nixos-module** — add option (next to `actionHost`):

```nix
s3Artifacts = lib.mkOption {
  type = lib.types.nullOr (lib.types.submodule {
    options = {
      publicBucket = lib.mkOption { type = lib.types.str; };
      privateBucket = lib.mkOption { type = lib.types.str; };
      publicBaseUrl = lib.mkOption { type = lib.types.str; };
    };
  });
  default = null;
  description = ''
    Build-artifact buckets (garnix.yaml `artifacts:`). Key pairs are read from
    /run/secrets/s3-artifacts-{public,private}-{access-key-id,secret-access-key}.
    Feature is off when null.
  '';
};
```

and the env export block (next to the `actionHost` one):

```nix
++ lib.optionals (config.services.garnixServer.s3Artifacts != null) [
  "S3_ARTIFACTS_PUBLIC_BUCKET=${config.services.garnixServer.s3Artifacts.publicBucket}"
  "S3_ARTIFACTS_PRIVATE_BUCKET=${config.services.garnixServer.s3Artifacts.privateBucket}"
  "S3_ARTIFACTS_PUBLIC_BASE_URL=${config.services.garnixServer.s3Artifacts.publicBaseUrl}"
]
```

- [ ] **Step 2: erdtree (dotfiles)** — in `garnixSecrets` add the four entries (blanket 0440 is fine — they're read as env-file secrets by the garnix user):

```nix
"s3-artifacts-public-access-key-id" = "garnix-s3-artifacts-public-access-key-id.age";
"s3-artifacts-public-secret-access-key" = "garnix-s3-artifacts-public-secret-access-key.age";
"s3-artifacts-private-access-key-id" = "garnix-s3-artifacts-private-access-key-id.age";
"s3-artifacts-private-secret-access-key" = "garnix-s3-artifacts-private-secret-access-key.age";
```

in `services.garnixServer`: `s3Artifacts = { publicBucket = garnixData.b2.artifactsPublicBucket; privateBucket = garnixData.b2.artifactsPrivateBucket; publicBaseUrl = garnixData.b2.artifactsPublicBaseUrl; };` and in the Caddy app-domain vhost, next to `@badges`:

```nix
# Artifact downloads: scripts fetch with garnix access tokens, so they must
# bypass the Authentik gate; the backend enforces session-or-token auth and
# repo access itself (public artifacts are anonymous by design).
@artifacts path /api/artifacts/*
handle @artifacts {
  reverse_proxy 127.0.0.1:8321
}
```

Gate: `nix eval --raw ~/dotfiles#nixosConfigurations.erdtree.config.system.build.toplevel.drvPath` succeeds (with the github token NIX_CONFIG, garnix-ci input pointed at the pushed commit — push the fork first or use an `--override-input garnix-ci path:$HOME/Development/garnix-ci` eval).

- [ ] **Step 3: README** — add an **Artifacts** section (after the Actions section): the yaml snippet, setup (buckets + 4 key secrets + `s3Artifacts` option + Caddy bypass block), latest-URL format `https://<garnixDomain>/api/artifacts/<owner>/<repo>/<branch>/<name>/latest.zip`, retention/lock/keep-latest semantics, curl-with-token example (`curl -u user:$TOKEN`), and a secrets-table row for the four artifact keys. Add a "What this fork adds" bullet. Update `skills/using-garnix-ci/SKILL.md` with a compact Artifacts section (yaml, latest URLs, Configure retention/locking, SSO-bypass note).

- [ ] **Step 4: Commit all three repos** — fork: `git commit -m "feat(artifacts): nixos-module s3Artifacts option + docs"`; dotfiles: `git commit -m "feat(erdtree): garnix artifact buckets + caddy bypass"`; agent-skills: `git commit -m "docs(using-garnix-ci): artifacts"`.

---

### Task 12: agent-skills migration (proof of parity)

**Files (agent-skills repo):**
- Modify: `flake.nix` (add `web-skills-zips` package near `web-skills`, line ~153), `garnix.yaml`
- Delete: `.github/workflows/build-web-skills.yml`

- [ ] **Step 1: Derivation** — next to `web-skills`:

```nix
# One zip per skill (zip root = exactly one folder + one SKILL.md), the layout
# the Claude web "Customize > Skills" upload UI requires. Published as a
# garnix artifact (garnix.yaml `artifacts:`), replacing the GitHub workflow.
web-skills-zips = pkgs.runCommand "web-skills-zips" { nativeBuildInputs = [ pkgs.zip ]; } ''
  mkdir -p $out staging
  cp -rL ${web-skills}/. staging/
  chmod -R u+w staging
  cd staging
  for name in */; do
    name="''${name%/}"
    zip -q -r -X "$out/$name.zip" "$name"
  done
'';
```

(and export it in `packages` beside `web-skills`). Gate: `nix build ~/Development/agent-skills#web-skills-zips --no-link` exit 0 and the result contains one zip per skill.

- [ ] **Step 2: `garnix.yaml`** — add (creating the file if absent, alongside any existing sections):

```yaml
artifacts:
  - package: web-skills-zips
    name: claude-skills
```

- [ ] **Step 3: Delete the workflow** — `git rm .github/workflows/build-web-skills.yml`.

- [ ] **Step 4: Commit + push agent-skills** — `git commit -m "feat: publish claude-skills via garnix artifacts, drop GitHub workflow"` and push (the next garnix build of the repo exercises the whole pipeline end-to-end).

---

### Final gates (after all tasks)

- [ ] Backend: `nix build ~/Development/garnix-ci#backend_garnixHaskellPackage --no-link --print-out-paths` exit 0 (authoritative sandboxed pg build).
- [ ] Checks: `nix build ~/Development/garnix-ci#checks.x86_64-linux.backend_hlint --no-link` and `...frontend_knip` both succeed.
- [ ] Fast suite: `cabal run test:spec -- --skip "@slow"` — no NEW failures vs. the known environmental baseline (~143: nix/git/GitHub-auth/S3-dependent + pre-existing forge-golden drift).
- [ ] Push fork `main`; bump dotfiles `flake.lock` (`nix flake update garnix-ci` with the gh token) and commit. **Do not deploy erdtree** — after the operator deploys, the agent-skills push (Task 12) is the live end-to-end test.
