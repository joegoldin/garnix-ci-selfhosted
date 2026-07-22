import { z } from "zod";
import { APIResult, fetchFromAPI } from ".";

const haskellUnionVariantWithContents = <
  Tag extends string,
  Contents extends z.ZodTypeAny,
>(
  tag: Tag,
  contents: Contents,
) => z.object({ tag: z.literal(tag), contents });

// A resource sample pushed by a deployed server's guest reporter. CPU is a
// utilisation percentage (0-100); memory is in kibibytes.
const serverStatsSampleSchema = z.object({
  cpu_pct: z.number(),
  mem_used_kb: z.number(),
  mem_total_kb: z.number(),
  sampled_at: z.coerce.date(),
});

const runningServerSchema = z.object({
  id: z.string(),
  status: z.union([
    z.literal("Online"),
    z.literal("Failed"),
    z.literal("Booting"),
    z.literal("Ended"),
  ]),
  type: z.union([
    haskellUnionVariantWithContents("BranchDeployment", z.string()),
    haskellUnionVariantWithContents("GhPrDeployment", z.number()),
  ]),
  repo_owner: z.string(),
  repo_name: z.string(),
  package_name: z.string(),
  configuration_build_id: z.string(),
  commit: z.string(),
  ipv4: z.string().optional(),
  created_at: z.coerce.date().optional(),
  deploy_logs: z.string(),
  url: z.string(),
  // Extra hostnames declared for this server (garnix.yaml servers[].domains),
  // beyond the default deployed `url`. Used by the Servers-page DNS-help modal.
  domains: z.array(z.string()).default([]),
  // Real login usernames captured from the guest at deploy time (getent
  // passwd, minus service/nologin accounts). Used by the terminal page's
  // "Login as" picker to suggest valid usernames beyond the default.
  ssh_users: z.array(z.string()).default([]),
  // Per-server SSH/port exposure (servers.exposed); null when nothing exposed.
  exposed: z
    .object({
      ssh_port: z
        .number()
        .nullish()
        .transform((v) => v ?? null),
      // The login user garnix authorized ("garnix"), or null when only your own
      // declared guest users can log in.
      ssh_user: z
        .string()
        .nullish()
        .transform((v) => v ?? null),
      tcp: z
        .array(
          z.object({
            name: z.string(),
            guest: z.number(),
            host: z.number(),
          }),
        )
        .nullish()
        .transform((v) => v ?? []),
      http: z
        .array(z.object({ name: z.string(), port: z.number() }))
        .nullish()
        .transform((v) => v ?? []),
    })
    .nullish()
    .transform((v) => v ?? null),
  // Latest resource sample from the server's guest reporter; null until the
  // guest has reported (or the reporter isn't configured).
  stats: serverStatsSampleSchema.nullish().transform((v) => v ?? null),
});
export type RunningServer = z.infer<typeof runningServerSchema>;

// Current sample + a short rolling window, for the per-server Monitor page.
const serverStatsHistorySchema = z.object({
  current: serverStatsSampleSchema.nullish().transform((v) => v ?? null),
  samples: z.array(serverStatsSampleSchema),
});
export type ServerStatsHistory = z.infer<typeof serverStatsHistorySchema>;

const serverLogStreamSchema = z.object({
  configured: z.boolean(),
  connected: z.boolean(),
  lines: z.array(z.string()),
  error: z
    .string()
    .nullish()
    .transform((value) => value ?? null),
});
export type ServerLogStream = z.infer<typeof serverLogStreamSchema>;

export async function getRunningServers(): Promise<
  APIResult<Array<RunningServer>>
> {
  return await fetchFromAPI(z.array(runningServerSchema), "GET", "hosts");
}

export async function deleteServer(id: string): Promise<APIResult<null>> {
  return await fetchFromAPI(z.null(), "DELETE", `hosts/${id}`);
}

// Kick off a fresh build+deploy job for this server's branch/PR. The backend
// resolves the server's repo + ref and re-runs the pipeline (which redeploys).
export async function redeployServer(id: string): Promise<APIResult<null>> {
  return await fetchFromAPI(z.null(), "POST", `hosts/${id}/redeploy`);
}

export async function getServerStats(
  id: string,
): Promise<APIResult<ServerStatsHistory>> {
  return await fetchFromAPI(
    serverStatsHistorySchema,
    "GET",
    `hosts/${id}/stats`,
  );
}

export async function getServerLogStream(
  id: string,
): Promise<APIResult<ServerLogStream>> {
  return await fetchFromAPI(serverLogStreamSchema, "GET", `hosts/${id}/logs`);
}
