import { z } from "zod";
import { APIResult, fetchFromAPI } from ".";

const settingsSchema = z
  .object({
    // A Nothing field may be omitted by the backend, so tolerate absent/null.
    default_build_timeout_minutes: z
      .number()
      .nullish()
      .transform((v) => v ?? null),
    default_max_eval_memory_gib: z
      .number()
      .nullish()
      .transform((v) => v ?? 16),
    repo_overrides: z.array(
      z.object({
        repo_user: z.string(),
        repo_name: z.string(),
        build_timeout_minutes: z
          .number()
          .nullish()
          .transform((v) => v ?? null),
        max_eval_memory_gib: z
          .number()
          .nullish()
          .transform((v) => v ?? null),
        default_authentik_approved: z
          .boolean()
          .nullish()
          .transform((v) => v ?? false),
      }),
    ),
    // Artifact settings; tolerate a backend that predates artifacts (absent
    // fields fall back to the server-side defaults: 30 days, no keep-latest).
    artifact_retention_days: z
      .number()
      .nullish()
      .transform((v) => v ?? 30),
    artifact_keep_latest: z
      .boolean()
      .nullish()
      .transform((v) => v ?? false),
    artifact_repo_overrides: z
      .array(
        z.object({
          repo_user: z.string(),
          repo_name: z.string(),
          retention_days: z
            .number()
            .nullish()
            .transform((v) => v ?? null),
          keep_latest: z
            .boolean()
            .nullish()
            .transform((v) => v ?? null),
        }),
      )
      .nullish()
      .transform((v) => v ?? []),
    artifact_usage: z
      .array(
        z.object({
          repo_user: z.string(),
          repo_name: z.string(),
          total_size: z.number(),
        }),
      )
      .nullish()
      .transform((v) => v ?? []),
    locked_artifact_builds: z
      .array(
        z.object({
          build_id: z.string(),
          repo_user: z.string(),
          repo_name: z.string(),
          branch: z
            .string()
            .nullish()
            .transform((v) => v ?? null),
          name: z.string(),
          created_at: z.coerce.date(),
        }),
      )
      .nullish()
      .transform((v) => v ?? []),
  })
  .transform((s) => ({
    defaultBuildTimeoutMinutes: s.default_build_timeout_minutes,
    defaultMaxEvalMemoryGib: s.default_max_eval_memory_gib,
    repoOverrides: s.repo_overrides.map((o) => ({
      repoUser: o.repo_user,
      repoName: o.repo_name,
      buildTimeoutMinutes: o.build_timeout_minutes,
      maxEvalMemoryGib: o.max_eval_memory_gib,
      defaultAuthentikApproved: o.default_authentik_approved,
    })),
    artifactRetentionDays: s.artifact_retention_days,
    artifactKeepLatest: s.artifact_keep_latest,
    artifactRepoOverrides: s.artifact_repo_overrides.map((o) => ({
      repoUser: o.repo_user,
      repoName: o.repo_name,
      retentionDays: o.retention_days,
      keepLatest: o.keep_latest,
    })),
    artifactUsage: s.artifact_usage.map((u) => ({
      repoUser: u.repo_user,
      repoName: u.repo_name,
      totalSize: u.total_size,
    })),
    lockedArtifactBuilds: s.locked_artifact_builds.map((b) => ({
      buildId: b.build_id,
      repoUser: b.repo_user,
      repoName: b.repo_name,
      branch: b.branch,
      name: b.name,
      createdAt: b.created_at,
    })),
  }));

export type ConfigureSettings = z.infer<typeof settingsSchema>;
export type RepoOverride = ConfigureSettings["repoOverrides"][number];
export type ArtifactRepoOverride =
  ConfigureSettings["artifactRepoOverrides"][number];
export type LockedArtifactBuild =
  ConfigureSettings["lockedArtifactBuilds"][number];

export const getConfigureSettings = async (): Promise<
  APIResult<ConfigureSettings>
> => await fetchFromAPI(settingsSchema, "GET", "configure");

// Mutations return NoContent (empty body -> {}); accept anything.
export const setDefaultBuildTimeout = async (
  minutes: number | null,
): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.any(), "PUT", "configure/default", {
    body: JSON.stringify({ minutes }),
  });

export const setRepoBuildTimeout = async (
  owner: string,
  repo: string,
  minutes: number,
): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.any(), "PUT", `configure/repo/${owner}/${repo}`, {
    body: JSON.stringify({ minutes }),
  });

export const deleteRepoBuildTimeout = async (
  owner: string,
  repo: string,
): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.any(), "DELETE", `configure/repo/${owner}/${repo}`);

export const setRepoEvaluationMemory = async (
  owner: string,
  repo: string,
  gibibytes: number,
): Promise<APIResult<unknown>> =>
  await fetchFromAPI(
    z.any(),
    "PUT",
    `configure/repo/${owner}/${repo}/evaluation-memory`,
    { body: JSON.stringify({ gibibytes }) },
  );

export const deleteRepoEvaluationMemory = async (
  owner: string,
  repo: string,
): Promise<APIResult<unknown>> =>
  await fetchFromAPI(
    z.any(),
    "DELETE",
    `configure/repo/${owner}/${repo}/evaluation-memory`,
  );

// Approve (or revoke) a repo for `authentik: default` hosting, which lets its
// deployed servers reuse garnix's own OIDC login/client credentials. JSON key
// is `approved` to match the backend SetDefaultAuthentikDto codec.
export const setRepoDefaultAuthentik = async (
  owner: string,
  repo: string,
  approved: boolean,
): Promise<APIResult<unknown>> =>
  await fetchFromAPI(
    z.any(),
    "PUT",
    `configure/repo/${owner}/${repo}/default-authentik`,
    { body: JSON.stringify({ approved }) },
  );

export const setDefaultArtifactSettings = async (
  retentionDays: number,
  keepLatest: boolean,
): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.any(), "PUT", "configure/artifacts/default", {
    body: JSON.stringify({
      retention_days: retentionDays,
      keep_latest: keepLatest,
    }),
  });

// A null field means "inherit the global setting".
export const setRepoArtifactSettings = async (
  owner: string,
  repo: string,
  retentionDays: number | null,
  keepLatest: boolean | null,
): Promise<APIResult<unknown>> =>
  await fetchFromAPI(
    z.any(),
    "PUT",
    `configure/artifacts/repo/${owner}/${repo}`,
    {
      body: JSON.stringify({
        retention_days: retentionDays,
        keep_latest: keepLatest,
      }),
    },
  );

export const deleteRepoArtifactSettings = async (
  owner: string,
  repo: string,
): Promise<APIResult<unknown>> =>
  await fetchFromAPI(
    z.any(),
    "DELETE",
    `configure/artifacts/repo/${owner}/${repo}`,
  );

const connectedDomainSchema = z.object({
  id: z
    .number()
    .nullish()
    .transform((value) => value ?? null),
  domain: z.string(),
  is_wildcard: z.boolean(),
  verified: z.boolean(),
  nix_configured: z
    .boolean()
    .optional()
    .transform((value) => value ?? false),
});

export type ConnectedDomain = z.infer<typeof connectedDomainSchema>;

export const getConnectedDomains = async (): Promise<
  APIResult<Array<ConnectedDomain>>
> =>
  await fetchFromAPI(
    z.array(connectedDomainSchema),
    "GET",
    "configure/domains",
  );

export const addConnectedDomain = async (
  domain: string,
): Promise<APIResult<ConnectedDomain>> =>
  await fetchFromAPI(connectedDomainSchema, "POST", "configure/domains", {
    body: JSON.stringify({ domain }),
  });

export const verifyConnectedDomain = async (
  id: number,
): Promise<APIResult<ConnectedDomain>> =>
  await fetchFromAPI(
    connectedDomainSchema,
    "POST",
    `configure/domains/${id}/verify`,
  );

export const verifyConfiguredDomain = async (
  domain: string,
): Promise<APIResult<ConnectedDomain>> =>
  await fetchFromAPI(
    connectedDomainSchema,
    "POST",
    "configure/domains/configured/verify",
    { body: JSON.stringify({ domain }) },
  );

export const deleteConnectedDomain = async (
  id: number,
): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.any(), "DELETE", `configure/domains/${id}`);

const repoRefSchema = z.object({ owner: z.string(), repo: z.string() });
export type RepoRef = z.infer<typeof repoRefSchema>;

// Every repo garnix has built for, for the Configure page's quick-links list.
export const getBuiltRepos = async (): Promise<APIResult<Array<RepoRef>>> =>
  await fetchFromAPI(z.array(repoRefSchema), "GET", "configure/repos");
