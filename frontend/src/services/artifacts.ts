import { z } from "zod";
import { APIResult, fetchFromAPI } from ".";

const artifactSchema = z.object({
  id: z.number(),
  // The build's hashid slug, same format the build page URL uses.
  build_id: z.string(),
  repo_user: z.string(),
  repo_name: z.string(),
  branch: z
    .string()
    .nullish()
    .transform((v) => v ?? null),
  name: z.string(),
  store_hash: z.string(),
  status: z.string(),
  locked: z.boolean(),
  created_at: z.coerce.date(),
  total_size: z.number(),
  file_count: z.number(),
});
export type Artifact = z.infer<typeof artifactSchema>;

const manifestSchema = z.object({
  files: z.array(
    z.object({
      path: z.string(),
      size: z.number(),
      sha256: z.string(),
      executable: z.boolean(),
    }),
  ),
  total_size: z.number(),
  file_count: z.number(),
  store_hash: z.string(),
});
export type ArtifactManifest = z.infer<typeof manifestSchema>;

export const getBuildArtifacts = async (
  buildId: string,
): Promise<APIResult<Array<Artifact>>> =>
  await fetchFromAPI(z.array(artifactSchema), "GET", `artifacts/build/${buildId}`);

// All of a repo's artifacts (newest first), for the "View Artifacts" page.
export const getRepoArtifacts = async (
  owner: string,
  repo: string,
): Promise<APIResult<Array<Artifact>>> =>
  await fetchFromAPI(
    z.array(artifactSchema),
    "GET",
    `artifacts/repo/${owner}/${repo}`,
  );

// A single commit's artifacts across all of its builds, for the commit page's
// per-row artifact icons and the "View Artifacts" page's commit filter.
export const getCommitArtifacts = async (
  owner: string,
  repo: string,
  commit: string,
): Promise<APIResult<Array<Artifact>>> =>
  await fetchFromAPI(
    z.array(artifactSchema),
    "GET",
    `artifacts/commit/${owner}/${repo}/${commit}`,
  );

const commitCountSchema = z.object({
  commit: z.string(),
  count: z.number(),
});
export type ArtifactCommitCount = z.infer<typeof commitCountSchema>;

// Published-artifact counts per commit, for the repo build-list page's
// per-row badges.
export const getArtifactCommitCounts = async (
  owner: string,
  repo: string,
): Promise<APIResult<Array<ArtifactCommitCount>>> =>
  await fetchFromAPI(
    z.array(commitCountSchema),
    "GET",
    `artifacts/repo/${owner}/${repo}/commit-counts`,
  );

// The manifest endpoint 302s to storage; fetch follows the redirect and
// returns the manifest JSON from the bucket.
export const getArtifactManifest = async (
  buildId: string,
  name: string,
): Promise<APIResult<ArtifactManifest>> =>
  await fetchFromAPI(
    manifestSchema,
    "GET",
    `artifacts/build/${buildId}/${encodeURIComponent(name)}/manifest`,
  );

// Lock/unlock return NoContent (empty body); accept anything.
export const lockBuildArtifacts = async (
  buildId: string,
): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.unknown(), "POST", `artifacts/build/${buildId}/lock`);

export const unlockBuildArtifacts = async (
  buildId: string,
): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.unknown(), "DELETE", `artifacts/build/${buildId}/lock`);

// Download URLs are plain hrefs (the endpoints 302 to storage), not fetches.
export const artifactZipUrl = (buildId: string, name: string): string =>
  `/api/artifacts/build/${buildId}/${encodeURIComponent(name)}/all.zip`;

export const artifactManifestUrl = (buildId: string, name: string): string =>
  `/api/artifacts/build/${buildId}/${encodeURIComponent(name)}/manifest`;

export const artifactFileUrl = (
  buildId: string,
  name: string,
  path: string,
): string =>
  `/api/artifacts/build/${buildId}/${encodeURIComponent(name)}/files/${path
    .split("/")
    .map(encodeURIComponent)
    .join("/")}`;

// The stable per-branch URL; null for branchless builds (e.g. PR merge
// commits), which have no latest pointer.
export const artifactLatestZipUrl = (
  a: Pick<Artifact, "repo_user" | "repo_name" | "branch" | "name">,
): string | null =>
  a.branch
    ? `/api/artifacts/${a.repo_user}/${a.repo_name}/${encodeURIComponent(
        a.branch,
      )}/${encodeURIComponent(a.name)}/latest.zip`
    : null;
