import { z } from "zod";
import { APIResult, fetchFromAPI } from ".";

const privateInputForkRequestSchema = z
  .object({
    repo_user: z.string(),
    repo_name: z.string(),
    allowed: z.boolean(),
    blocked_at: z.coerce.date(),
  })
  .transform((request) => ({
    repoUser: request.repo_user,
    repoName: request.repo_name,
    allowed: request.allowed,
    blockedAt: request.blocked_at,
  }));

export type PrivateInputForkRequest = z.infer<
  typeof privateInputForkRequestSchema
>;

// Only repositories that have actually been blocked after an external fork
// requested private inputs are returned here. Trusted builds never create a
// request even though their cache is automatically private.
export const getPrivateInputForkRequests = async (): Promise<
  APIResult<Array<PrivateInputForkRequest>>
> =>
  await fetchFromAPI(
    z.array(privateInputForkRequestSchema),
    "GET",
    "admin/private-input-forks",
  );

export const setPrivateInputForkApproval = async (
  owner: string,
  repo: string,
  allowed: boolean,
): Promise<APIResult<unknown>> =>
  await fetchFromAPI(
    z.unknown(),
    "PUT",
    `admin/private-input-forks/${owner}/${repo}`,
    { body: JSON.stringify({ allowed }) },
  );
