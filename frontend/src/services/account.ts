import { z } from "zod";
import { fromSecs } from "@/utils/duration";
import { mapCollectResult } from "@/utils";
import { APIResult, Err, Ok, fetchFromAPI } from ".";

type Usage = {
  byOrg: Record<string, OrgUsage>;
};

// This self-host fork has no billing: a "plan" only carries a display name.
const planSchema = z.object({
  display_name: z.string(),
  description: z.optional(z.string()),
});

export type OrgUsage = z.infer<typeof orgUsageSchema>;
const orgUsageSchema = z.object({
  ci_time: z.number().transform(fromSecs),
  pr_deployment_time: z.number().transform(fromSecs),
  branch_deployment_hosts: z.number(),
  plan: planSchema,
});
const usageResponseSchema = z.object({
  by_org: z.record(z.string(), orgUsageSchema),
});

export const getAccountUsage = async (): Promise<APIResult<Usage>> => {
  const res = await fetchFromAPI(usageResponseSchema, "GET", "account/usage");
  if (!res.ok) return res;
  return Ok({ byOrg: res.data.by_org });
};

export const getOrgUsage = (org: string): Promise<APIResult<OrgUsage>> => {
  return fetchFromAPI(orgUsageSchema, "GET", `account/usage/${org}`);
};

export type AccountTokenScopes = z.infer<typeof accountTokenScopes>;
const accountTokenScopes = z.object({
  cache: z.boolean(),
  api: z.boolean(),
});

const accessTokenMetadata = z.object({
  id: z.number(),
  name: z.string(),
  created: z.coerce.date(),
  last_used: z.coerce.date().optional(),
  scopes: accountTokenScopes,
});

export const getAccessTokens = () => {
  return fetchFromAPI(
    z.object({ tokens: z.array(accessTokenMetadata) }),
    "GET",
    "account/tokens",
  );
};

type AccountTokensConfig = {
  name: string;
  scopes: AccountTokenScopes;
};

export const generateAccessToken = (body: AccountTokensConfig) => {
  return fetchFromAPI(z.object({ token: z.string() }), "POST", "account/tokens", {
    body: JSON.stringify(body),
  });
};

export const revokeAccessToken = (tokenId: number) => {
  return fetchFromAPI(z.unknown(), "DELETE", `account/tokens/${tokenId}`);
};

export const getRepos = async () => {
  const result = await fetchFromAPI(
    z.object({ repos: z.array(z.string()) }),
    "GET",
    "account/repos",
  );
  if (!result.ok) return result;
  return mapCollectResult((repo) => {
    const [repoUser, repoName] = repo.split("/");
    if (!repoUser || !repoName) {
      return Err({ message: `Unable to parse repo: ${repo}` });
    }
    return Ok({ repoUser, repoName });
  }, result.data.repos);
};
