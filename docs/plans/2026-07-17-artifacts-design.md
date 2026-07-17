# Build Artifacts — Design

Replace GitHub Actions artifacts for repos built on this self-host fork:
downloadable, retained, lockable bundles produced from **nix build outputs**,
stored in two dedicated Backblaze B2 buckets, served through garnix with
stable "latest" URLs. Motivating example: `joegoldin/agent-skills`'
`build-web-skills.yml`, which builds `.#web-skills`, zips each skill folder,
and uploads a `claude-skills` artifact — all of which this feature absorbs
into `garnix.yaml` + the flake.

## Decisions (settled with the operator)

| Question | Decision |
|---|---|
| Producer | Declarative: `garnix.yaml` `artifacts:` names packages whose build outputs are published. No imperative upload API. |
| Serving | File browser (per-file downloads) + a "download all" zip per artifact. |
| Private delivery | Authed garnix endpoint → 302 to a short-lived presigned B2 URL (same pattern as the private cache). Public bucket → 302 to its public URL. |
| Latest URLs | Stable per (repo, branch, artifact-name) URLs resolving to the newest published artifact. |
| Retention | Global default lifetime + per-repo override, set on the Configure page. |
| Keep-latest | Configurable exemption (global default + per-repo override), **default off**: when on, the newest artifact per (repo, branch, name) is never reaped. |
| Locking | Per-build lock/unlock (Configure page + build page): locked artifacts are never reaped. |
| Storage | Content-addressed under `artifacts/<storeHash>/`; builds whose output is unchanged upload nothing and share objects. Reaper garbage-collects unreferenced hashes. |
| Buckets | `joegoldin-garnix-artifacts-public` (public visibility) / `joegoldin-garnix-artifacts-private`, routed by the same repo-publicity rules as the cache. Created; per-bucket B2 keys provisioned in dotfiles-secrets. |

## 1. `garnix.yaml`

```yaml
artifacts:
  - package: web-skills-zips   # packages.<arch>.web-skills-zips
    name: claude-skills        # optional; defaults to the package name
```

- `package` (required): the flake package whose `out` output is published.
  Declared packages are **auto-included in builds** (same rule as
  `servers[].configuration`), so an `artifacts:` entry alone is enough.
- `name` (optional): the artifact's display/URL name. Must be unique within
  the repo's config; `[a-zA-Z0-9._-]+`.
- Publishes on every **successful** build of the package (branch and PR
  builds alike). Latest-URL resolution only considers branch builds.

## 2. Storage layout & publish pipeline

Bucket per artifact, chosen at publish time by the same rule as the cache
(`ServedPathVisibility`): public repo → public bucket, private repo or
repo routed private (`private_cache` / private flake inputs) → private bucket.

Object layout (content-addressed; `<storeHash>` = the 32-char nix hash of the
package's `out` store path):

```
artifacts/<storeHash>/files/<relative path>   one object per regular file
artifacts/<storeHash>/all.zip                 the whole output, zipped
artifacts/<storeHash>/manifest.json           {files: [{path, size, sha256, executable}], total_size, file_count, store_hash}
```

Publish steps (in the build pipeline, after the package build succeeds and
its outputs are known):

1. Look up `artifact_objects` for `(store_hash, bucket)`. If present, skip
   uploads entirely (dedupe) and go to step 4.
2. Walk the store output **dereferencing symlinks** (like the workflow's
   `cp -rL`); a dangling symlink fails the publish. Upload each regular
   file; record executable bits in the manifest and as zip unix modes.
3. Build `all.zip` (in a temp dir) and `manifest.json`; upload both. Insert
   `artifact_objects` row.
4. Upsert the `artifacts` row on `(build_id, name)` — a restarted build
   republishes over its old row rather than conflicting.

A failed publish marks the artifact row failed (visible on the build page)
without failing the build itself; the next push retries naturally.

## 3. Database

```sql
CREATE TABLE artifact_objects (          -- one row per stored content blob
  store_hash text NOT NULL,
  bucket     text NOT NULL,              -- 'public' | 'private'
  total_size bigint NOT NULL,
  file_count int NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_hash, bucket)
);

CREATE TABLE artifacts (                 -- one row per (build, artifact name)
  id          bigserial PRIMARY KEY,
  build_id    bigint NOT NULL REFERENCES builds(id),
  repo_user   text NOT NULL,
  repo_name   text NOT NULL,
  branch      text,                      -- null only if the build has none
  name        text NOT NULL,
  store_hash  text NOT NULL,
  bucket      text NOT NULL,
  status      text NOT NULL,             -- 'published' | 'failed'
  locked      boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (build_id, name)
);
```

Settings (Configure page persistence, same tables as build timeouts):

- `server_settings`: `artifact_retention_days int NOT NULL DEFAULT 30`,
  `artifact_keep_latest boolean NOT NULL DEFAULT false`.
- `repo_config`: `artifact_retention_days int NULL`,
  `artifact_keep_latest boolean NULL` (tri-state override).

## 4. API

Listing / metadata (session-authed like the rest of `/api`):

```
GET /api/artifacts/repo/<owner>/<repo>[?branch=]   rows for a repo
GET /api/artifacts/build/<buildId>                 rows for a build
```

Downloads (branch segments URL-encode slashes, e.g. `feature%2Ffoo`):

```
GET /api/artifacts/build/<buildId>/<name>.zip
GET /api/artifacts/build/<buildId>/<name>/manifest
GET /api/artifacts/build/<buildId>/<name>/files/<path...>
GET /api/artifacts/<owner>/<repo>/<branch>/<name>/latest.zip
GET /api/artifacts/<owner>/<repo>/<branch>/<name>/latest/manifest
GET /api/artifacts/<owner>/<repo>/<branch>/<name>/latest/files/<path...>
```

Management (admin only):

```
POST   /api/artifacts/build/<buildId>/lock        lock all the build's artifacts
DELETE /api/artifacts/build/<buildId>/lock        unlock
DELETE /api/artifacts/<artifactId>                delete row (objects GC'd later)
```

**Download auth.** Downloads must work for browsers *and* curl/scripts:

- Public-repo artifacts: anonymous (they 302 to the public bucket anyway).
- Private: a valid session (proxy headers → JWT) **or** an access token with
  the `api` scope, accepted as `Authorization: Bearer <token>` or as the
  basic-auth password (netrc-compatible, same as the cache).
- The self-host reverse proxy must **bypass the SSO gate for
  `/api/artifacts/*`** (like `/api/keys/*` and `/api/badges/*`); the backend
  enforces the rules above itself. Documented in the README's Caddy block.

Delivery: resolve row → bucket. Public: 302 to
`<artifactsPublicBaseUrl>/artifacts/<hash>/...`. Private: 302 to a presigned
URL (10-minute TTL) minted with the private-bucket key.

## 5. Retention reaper

A `NoThrow.forkForever` loop (hourly):

1. Effective settings per repo: `repo_config` override else `server_settings`.
2. Delete `artifacts` rows where `status='published'`, `NOT locked`,
   `created_at < now() - retention`, and **not** (keep-latest effective AND
   the row is the newest published row for its `(repo_user, repo_name,
   branch, name)`).
3. GC: delete `artifact_objects` rows (and their S3 prefixes, via listed
   deletes under `artifacts/<hash>/`) that no `artifacts` row references.

Failed rows older than 7 days are pruned unconditionally.

## 6. Frontend

- **Build page**: an Artifacts section per build — name, total size, file
  count, expandable file list (name, size, sha256 tooltip, download link),
  "Download .zip", a "latest" badge when the row is the branch's newest, and
  (admin) a lock toggle.
- **Configure page**: an **Artifacts** card —
  - global retention days + keep-latest toggle;
  - per-repo override table (retention, keep-latest), same interaction as
    build-timeout overrides;
  - storage usage: total + per-repo (SUM over referenced
    `artifact_objects`, dedupe-aware);
  - locked builds list (repo, build link, age, unlock button);
  - copyable latest-URL per (repo, branch, name) seen in `artifacts` rows.

## 7. Configuration & secrets

Backend env (nixos-module option `services.garnixServer.s3Artifacts`,
feature **off** when unset):

```
S3_ARTIFACTS_PUBLIC_BUCKET / S3_ARTIFACTS_PRIVATE_BUCKET
S3_ARTIFACTS_PUBLIC_BASE_URL
S3_ARTIFACTS_PUBLIC_ACCESS_KEY_ID / S3_ARTIFACTS_PUBLIC_SECRET_ACCESS_KEY
S3_ARTIFACTS_PRIVATE_ACCESS_KEY_ID / S3_ARTIFACTS_PRIVATE_SECRET_ACCESS_KEY
```

Key env vars fall back to `/run/secrets/s3-artifacts-{public,private}-…`
(matching the cache pattern). Host/region reuse `S3_CACHE_HOST/REGION` (same
B2 account). Erdtree wiring: four agenix secrets (already provisioned in
dotfiles-secrets), bucket names from `garnixData.b2.artifacts*`.

## 8. agent-skills migration (proof of parity)

1. Flake: add `packages.web-skills-zips` — zips each skill folder of
   `web-skills` (the workflow's packaging step, as a derivation).
2. `garnix.yaml`: `artifacts: [{package: web-skills-zips, name: claude-skills}]`.
3. Delete `.github/workflows/build-web-skills.yml`.
4. Stable URL: `https://<garnixDomain>/api/artifacts/joegoldin/agent-skills/main/claude-skills/latest.zip`
   (or per-skill: `.../latest/files/<skill>.zip`).

## Edge cases

- **Publicity flip**: rows keep serving from their recorded bucket; the next
  successful build publishes to the newly-correct bucket. No migration of old
  objects.
- **Same output, different names/repos**: rows share the `artifact_objects`
  blob; GC only removes it when the last row goes.
- **Renamed artifact**: old rows keep the old name until reaped; latest URL
  under the new name starts at the first build that used it.
- **Huge outputs**: uploads stream file-by-file; `all.zip` is staged in a
  server temp dir — outputs larger than free disk fail the publish with a
  clear error.

## Testing

- Publish pipeline: spec with a mocked S3 layer — dedupe (second publish of
  same hash uploads nothing), manifest correctness (sizes/sha256/exec bits),
  symlink dereference, dangling symlink failure.
- Reaper: dev-pg specs for retention math, lock exemption, keep-latest
  exemption (global + repo override), object GC only when unreferenced.
- API: latest resolution (branch builds only, newest wins), access checks
  (private repo anonymous → 401/404, token → 302), slashed branch names.
- YamlConfig: `artifacts:` codec + golden schema update.

## Out of scope

- Imperative upload API from `actions:` steps (declared-output artifacts only).
- Cross-instance artifact replication; CDN fronting; artifact diffing.
- Per-artifact (row-level) locks — locking is per build.
