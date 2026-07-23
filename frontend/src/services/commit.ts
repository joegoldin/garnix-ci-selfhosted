import { z } from "zod";
import { Build, buildSchema } from "./build";
import { Run, runSchema } from "./run";
import { WaitNode, waitNodeSchema } from "./waiting";
import { APIResult, Ok, fetchFromAPI } from ".";

const commitSummarySchema = z
  .object({
    repo_owner: z.string(),
    repo_name: z.string(),
    git_commit: z.string(),
    branch: z.string().optional(),
    req_user: z.string(),
    start_time: z.coerce.date(),
    succeeded: z.number(),
    failed: z.number(),
    pending: z.number(),
    running: z.number(),
    cancelled: z.number(),
    forge: z.string(),
  })
  .transform((commit) => ({
    ...commit,
    repoUser: commit.repo_owner,
    repoName: commit.repo_name,
    gitCommit: commit.git_commit,
    reqUser: commit.req_user,
    startTime: commit.start_time,
  }));

export type CommitSummary = z.infer<typeof commitSummarySchema>;

export const getCommits = async (): Promise<
  APIResult<Array<CommitSummary>>
> => {
  const response = await fetchFromAPI(
    z.object({ commits: z.array(commitSummarySchema) }),
    "GET",
    "commits",
  );
  if (!response.ok) return response;
  return Ok(response.data.commits);
};

export const getCommitsForRepo = async (
  repoOwner: string,
  repoName: string,
): Promise<APIResult<Array<CommitSummary>>> => {
  const response = await fetchFromAPI(
    z.object({ commits: z.array(commitSummarySchema) }),
    "GET",
    `commits/repo/${repoOwner}/${repoName}`,
  );
  if (!response.ok) return response;
  return Ok(response.data.commits);
};

export const getCommit = async (
  commit: string,
): Promise<
  APIResult<{
    summary: CommitSummary;
    builds: Array<Build>;
    runs: Array<Run>;
    running_build_ids: Array<string>;
    waitingOn: Array<WaitNode>;
  }>
> => {
  return await fetchFromAPI(
    z
      .object({
        summary: commitSummarySchema,
        builds: z.array(buildSchema),
        runs: z.array(runSchema),
        running_build_ids: z.array(z.string()),
        waiting_on: z.array(waitNodeSchema).optional().default([]),
      })
      .transform((response) => ({
        ...response,
        waitingOn: response.waiting_on,
      })),
    "GET",
    `commits/${commit}`,
  );
};

// Cancels every in-progress build for the commit server-side, including the
// "overall" eval build that never appears in the builds list. Returns
// NoContent (empty body -> {}), so accept anything.
export const cancelCommit = async (
  commit: string,
): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.any(), "POST", `commits/${commit}/cancel`);

// Restarts every failed/timed-out build for the commit server-side (or the
// whole commit when the eval itself failed). NoContent response.
export const restartFailedCommit = async (
  commit: string,
): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.any(), "POST", `commits/${commit}/restart-failed`);

// Branches available to manually trigger a build on. GitHub repos list all
// branches live; Gitea repos list only the branches garnix has already seen.
export const getBranches = async (
  repoOwner: string,
  repoName: string,
): Promise<APIResult<Array<string>>> => {
  const response = await fetchFromAPI(
    z.object({ branches: z.array(z.string()) }),
    "GET",
    `commits/repo/${repoOwner}/${repoName}/branches`,
  );
  if (!response.ok) return response;
  return Ok(response.data.branches);
};

// Triggers a build for the branch's latest commit (a fresh eval on GitHub, or a
// re-run of the latest known commit on Gitea). Returns the commit that will be
// built so the caller can navigate to it.
export const triggerBuild = async (
  repoOwner: string,
  repoName: string,
  branch: string,
): Promise<APIResult<{ commit: string }>> =>
  await fetchFromAPI(
    z.object({ commit: z.string() }),
    "POST",
    `commits/repo/${repoOwner}/${repoName}/trigger`,
    { body: JSON.stringify({ branch }) },
  );
