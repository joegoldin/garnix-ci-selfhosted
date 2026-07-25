import { z } from "zod";
import { APIResult, fetchFromAPI } from ".";

const backupSchema = z.object({
  id: z.number(),
  // Hashid string, like every other server id in the API — not a number.
  server_id: z
    .string()
    .nullish()
    .transform((v) => v ?? null),
  repo_user: z.string(),
  repo_name: z.string(),
  branch: z
    .string()
    .nullish()
    .transform((v) => v ?? null),
  configuration: z.string(),
  persistence_name: z
    .string()
    .nullish()
    .transform((v) => v ?? null),
  object_hash: z
    .string()
    .nullish()
    .transform((v) => v ?? null),
  status: z.string(), // running | success | failed
  error: z
    .string()
    .nullish()
    .transform((v) => v ?? null),
  kind: z.string(), // scheduled | manual
  locked: z.boolean(),
  size: z
    .number()
    .nullish()
    .transform((v) => v ?? null),
  started_at: z.coerce.date(),
  finished_at: z.coerce
    .date()
    .nullish()
    .transform((v) => v ?? null),
});
export type Backup = z.infer<typeof backupSchema>;

const restoreSchema = z.object({
  id: z.number(),
  backup_id: z.number(),
  status: z.string(),
  error: z
    .string()
    .nullish()
    .transform((v) => v ?? null),
  initiated_by: z.string(),
  started_at: z.coerce.date(),
  finished_at: z.coerce
    .date()
    .nullish()
    .transform((v) => v ?? null),
});
export type BackupRestore = z.infer<typeof restoreSchema>;

export const getServerBackups = async (
  serverId: string,
): Promise<APIResult<Array<Backup>>> =>
  await fetchFromAPI(z.array(backupSchema), "GET", `backups/server/${serverId}`);

export const getServerRestores = async (
  serverId: string,
): Promise<APIResult<Array<BackupRestore>>> =>
  await fetchFromAPI(
    z.array(restoreSchema),
    "GET",
    `backups/server/${serverId}/restores`,
  );

export const getRepoBackups = async (
  owner: string,
  repo: string,
): Promise<APIResult<Array<Backup>>> =>
  await fetchFromAPI(z.array(backupSchema), "GET", `backups/repo/${owner}/${repo}`);

export const backupNow = async (serverId: string): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.any(), "POST", `backups/server/${serverId}/backup-now`);

export const restoreBackup = async (backupId: number): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.any(), "POST", `backups/${backupId}/restore`);

export const lockBackup = async (backupId: number): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.any(), "POST", `backups/${backupId}/lock`);

export const unlockBackup = async (backupId: number): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.any(), "DELETE", `backups/${backupId}/lock`);

export const deleteBackup = async (backupId: number): Promise<APIResult<unknown>> =>
  await fetchFromAPI(z.any(), "DELETE", `backups/${backupId}`);

// Downloads are 302s to presigned URLs — plain hrefs, not fetches.
export const backupDownloadUrl = (backupId: number): string =>
  `/api/backups/${backupId}/download`;

export const latestBackupUrl = (
  owner: string,
  repo: string,
  configuration: string,
): string =>
  `/api/backups/repo/${owner}/${repo}/${encodeURIComponent(configuration)}/latest.tar.zst`;
