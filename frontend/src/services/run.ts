import { z } from "zod";
import { APIResult, fetchFromAPI } from ".";

const runStatusSchema = z
  .union([
    z.literal("Failure"),
    z.literal("Success"),
    z.literal("Timeout"),
    z.literal("Cancelled"),
    // Completed without a pass or a failure (GitHub's `skipped` conclusion) —
    // e.g. a FOD check where nothing could be re-verified but nothing failed.
    z.literal("Skipped"),
  ])
  .optional();

export const runSchema = z
  .object({
    id: z.string(),
    name: z.string(),
    repo_user: z.string(),
    repo_name: z.string(),
    git_commit: z.string(),
    branch: z.string().optional(),
    status: runStatusSchema,
    start_time: z.coerce.date(),
    end_time: z.coerce.date().optional(),
    // Set once the run produces its first line of output (mirrors builds).
    run_started_at: z
      .coerce.date()
      .nullish()
      .transform((v) => v ?? null),
  })
  .transform((run) => ({
    ...run,
    tag: "Run" as const,
    repoUser: run.repo_user,
    repoName: run.repo_name,
    gitCommit: run.git_commit,
    startTime: run.start_time,
    endTime: run.end_time ?? null,
    runStartedAt: run.run_started_at,
    // Like builds: a run stays "Pending" until its first output, then shows
    // as "Running" until it finishes.
    status:
      run.status ??
      (run.run_started_at != null
        ? ("Running" as const)
        : ("Pending" as const)),
  }));

export type Run = z.infer<typeof runSchema>;

export const getRun = async (id: string): Promise<APIResult<Run>> => {
  return await fetchFromAPI(runSchema, "GET", `run/${id}`);
};

export const cancelRun = async (runId: string): Promise<APIResult<null>> => {
  return await fetchFromAPI(z.null(), "PUT", `run/${runId}`, {
    body: JSON.stringify({ status: "Cancelled" }),
  });
};
