import { z } from "zod";
import { APIResult, Ok, fetchFromAPI } from ".";

const repoConfigSchema = z.object({
  skip_private_inputs_check: z.boolean(),
  private_cache: z.boolean(),
});

export type RepoConfig = {
  skipPrivateInputsCheck: boolean;
  privateCache: boolean;
};

// Admin-only: read the per-repo config (whether a public repo may use private
// flake inputs, and whether its cache is routed to the private bucket).
export const getRepoConfig = async (
  owner: string,
  repo: string,
): Promise<APIResult<RepoConfig>> => {
  const res = await fetchFromAPI(
    repoConfigSchema,
    "GET",
    `admin/repo-config/${owner}/${repo}`,
  );
  if (!res.ok) return res;
  return Ok({
    skipPrivateInputsCheck: res.data.skip_private_inputs_check,
    privateCache: res.data.private_cache,
  });
};

// Admin-only: upsert the per-repo config.
export const setRepoConfig = (owner: string, repo: string, config: RepoConfig) =>
  fetchFromAPI(z.unknown(), "POST", `admin/repo-config/${owner}/${repo}`, {
    body: JSON.stringify({
      skip_private_inputs_check: config.skipPrivateInputsCheck,
      private_cache: config.privateCache,
    }),
  });
