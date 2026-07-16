import { z } from "zod";
import { APIResult, fetchFromAPI } from ".";

const haskellUnionVariantWithContents = <
  Tag extends string,
  Contents extends z.ZodTypeAny,
>(
  tag: Tag,
  contents: Contents,
) => z.object({ tag: z.literal(tag), contents });

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
  // Per-server SSH/port exposure (servers.exposed); null when nothing exposed.
  exposed: z
    .object({
      ssh_port: z
        .number()
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
});
export type RunningServer = z.infer<typeof runningServerSchema>;

export async function getRunningServers(): Promise<
  APIResult<Array<RunningServer>>
> {
  return await fetchFromAPI(z.array(runningServerSchema), "GET", "hosts");
}

export async function deleteServer(id: string): Promise<APIResult<null>> {
  return await fetchFromAPI(z.null(), "DELETE", `hosts/${id}`);
}
