import { z } from "zod";
import { APIResult, fetchFromAPI } from ".";

// A Maybe Double from the backend is omitted when Nothing (omitNothingFields),
// so every metric is nullish -> null. This also means a naming drift degrades
// to "—" rather than throwing.
const num = z
  .number()
  .nullish()
  .transform((v) => v ?? null);

const instanceSchema = z
  .object({
    eval_queue_len: num,
    s3_queue_len: num,
    fod_queue_len: num,
    package_builds_attempted: num,
    cache_push_success: num,
    cache_push_failure: num,
    scraped: z.boolean(),
  })
  .transform((s) => ({
    evalQueueLen: s.eval_queue_len,
    s3QueueLen: s.s3_queue_len,
    fodQueueLen: s.fod_queue_len,
    packageBuildsAttempted: s.package_builds_attempted,
    cachePushSuccess: s.cache_push_success,
    cachePushFailure: s.cache_push_failure,
    scraped: s.scraped,
  }));

const hostSchema = z
  .object({
    load1: num,
    load5: num,
    load15: num,
    mem_total_bytes: num,
    mem_used_bytes: num,
    disk_total_bytes: num,
    disk_avail_bytes: num,
    cpu_count: num,
    scraped: z.boolean(),
  })
  .transform((s) => ({
    load1: s.load1,
    load5: s.load5,
    load15: s.load15,
    memTotalBytes: s.mem_total_bytes,
    memUsedBytes: s.mem_used_bytes,
    diskTotalBytes: s.disk_total_bytes,
    diskAvailBytes: s.disk_avail_bytes,
    cpuCount: s.cpu_count,
    scraped: s.scraped,
  }));

const recentBuildSchema = z
  .object({
    name: z.string(),
    status: z.string().nullish().transform((v) => v ?? null),
    duration_secs: z.number(),
  })
  .transform((b) => ({
    name: b.name,
    status: b.status,
    durationSecs: b.duration_secs,
  }));

const jobsSchema = z
  .object({
    running_builds: z.number(),
    pending_builds: z.number(),
    running_runs: z.number(),
    pending_runs: z.number(),
    recent_builds: z.array(recentBuildSchema),
  })
  .transform((s) => ({
    runningBuilds: s.running_builds,
    pendingBuilds: s.pending_builds,
    runningRuns: s.running_runs,
    pendingRuns: s.pending_runs,
    recentBuilds: s.recent_builds,
  }));

const monitoringSchema = z
  .object({
    instance: instanceSchema,
    host: hostSchema,
    jobs: jobsSchema,
  })
  .transform((m) => ({
    instance: m.instance,
    host: m.host,
    jobs: m.jobs,
  }));

export type Monitoring = z.infer<typeof monitoringSchema>;
export type MonitoringInstance = Monitoring["instance"];
export type MonitoringHost = Monitoring["host"];
export type MonitoringJobs = Monitoring["jobs"];

export const getMonitoring = async (): Promise<APIResult<Monitoring>> =>
  await fetchFromAPI(monitoringSchema, "GET", "monitoring");
