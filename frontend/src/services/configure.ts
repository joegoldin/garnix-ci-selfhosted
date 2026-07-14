import { z } from "zod";
import { APIResult, fetchFromAPI } from ".";

const settingsSchema = z
  .object({
    // A Nothing field may be omitted by the backend, so tolerate absent/null.
    default_build_timeout_minutes: z
      .number()
      .nullish()
      .transform((v) => v ?? null),
    repo_overrides: z.array(
      z.object({
        repo_user: z.string(),
        repo_name: z.string(),
        build_timeout_minutes: z.number(),
      }),
    ),
  })
  .transform((s) => ({
    defaultBuildTimeoutMinutes: s.default_build_timeout_minutes,
    repoOverrides: s.repo_overrides.map((o) => ({
      repoUser: o.repo_user,
      repoName: o.repo_name,
      buildTimeoutMinutes: o.build_timeout_minutes,
    })),
  }));

export type ConfigureSettings = z.infer<typeof settingsSchema>;
export type RepoOverride = ConfigureSettings["repoOverrides"][number];

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
