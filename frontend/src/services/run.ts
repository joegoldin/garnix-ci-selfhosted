import { z } from "zod";
import { APIResult, fetchFromAPI } from ".";

// Unlike builds, a run row is created only when the run *starts* executing
// (FOD checks, module publish, actions, deployments) and never queues — so a
// not-yet-finished run is always "Running", not "Pending".
const runStatusSchema = z
  .union([
    z.literal("Failure"),
    z.literal("Success"),
    z.literal("Timeout"),
    z.literal("Cancelled"),
  ])
  .optional()
  .transform((s) => s ?? ("Running" as const));

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
  })
  .transform((run) => ({
    ...run,
    tag: "Run" as const,
    repoUser: run.repo_user,
    repoName: run.repo_name,
    gitCommit: run.git_commit,
    startTime: run.start_time,
    endTime: run.end_time ?? null,
  }));

export type Run = z.infer<typeof runSchema>;

export const getRun = async (id: string): Promise<APIResult<Run>> => {
  return await fetchFromAPI(runSchema, "GET", `run/${id}`);
};
