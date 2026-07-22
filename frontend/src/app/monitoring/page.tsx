"use client";

import { P, match } from "ts-pattern";
import { Text } from "@/components/text";
import { Table } from "@/components/table";
import { Loading } from "@/components/loading";
import { Link } from "@/components/link";
import { AppPage } from "@/utils/appPage";
import { useConfig } from "@/store/configContext";
import { useLoading } from "@/hooks/useLoading";
import { fromSecs } from "@/utils/duration";
import { Err, Ok } from "@/services";
import {
  getMonitoring,
  Monitoring,
  MonitoringInstance,
  MonitoringBuilder,
  MonitoringJobs,
} from "@/services/monitoring";
import { getRunningServers } from "@/services/servers";
import styles from "./styles.module.css";

// -- formatting helpers -------------------------------------------------------

const fmtNum = (n: number | null): string =>
  n == null ? "—" : n.toLocaleString();

const fmtFloat = (n: number | null, digits = 2): string =>
  n == null ? "—" : n.toFixed(digits);

const fmtBytes = (n: number | null): string => {
  if (n == null) return "—";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v.toFixed(i === 0 ? 0 : 1)} ${units[i]}`;
};

const fmtDuration = (secs: number): string => {
  if (secs < 60) return `${secs.toFixed(0)}s`;
  const m = Math.floor(secs / 60);
  const s = Math.round(secs % 60);
  return `${m}m ${s}s`;
};

const ratio = (num: number | null, den: number | null): string => {
  if (num == null && den == null) return "—";
  const n = num ?? 0;
  const d = den ?? 0;
  const total = n + d;
  if (total === 0) return "0 / 0";
  return `${n.toLocaleString()} ok / ${d.toLocaleString()} fail`;
};

// -- small presentational pieces ---------------------------------------------

const Stat = ({ label, value }: { label: string; value: string }) => (
  <div className={styles.stat}>
    <Text type="span" className={styles.statLabel}>
      {label}
    </Text>
    <Text type="span" className={styles.statValue}>
      {value}
    </Text>
  </div>
);

const NotScraped = ({ what }: { what: string }) => (
  <Text className={styles.help}>
    Couldn&apos;t reach {what}. Check that it&apos;s exporting metrics on the
    configured address.
  </Text>
);

// -- sections -----------------------------------------------------------------

const InstanceSection = ({ data }: { data: MonitoringInstance }) => (
  <>
    <Text type="h2" className={styles.h2}>
      Instance
    </Text>
    {!data.scraped && <NotScraped what="the garnix Prometheus endpoint" />}
    <div className={styles.statGrid}>
      <Stat label="Eval queue" value={fmtNum(data.evalQueueLen)} />
      <Stat label="Cache-push queue" value={fmtNum(data.s3QueueLen)} />
      <Stat label="FOD-check queue" value={fmtNum(data.fodQueueLen)} />
      <Stat
        label="Package builds attempted"
        value={fmtNum(data.packageBuildsAttempted)}
      />
      <Stat
        label="Cache pushes"
        value={ratio(data.cachePushSuccess, data.cachePushFailure)}
      />
    </div>
  </>
);

const BuilderStats = ({ data }: { data: MonitoringBuilder["stats"] }) => {
  const memUsedPct =
    data.memUsedBytes != null && data.memTotalBytes
      ? ` (${((data.memUsedBytes / data.memTotalBytes) * 100).toFixed(0)}%)`
      : "";
  const diskUsed =
    data.diskTotalBytes != null && data.diskAvailBytes != null
      ? data.diskTotalBytes - data.diskAvailBytes
      : null;
  const diskUsedPct =
    diskUsed != null && data.diskTotalBytes
      ? ` (${((diskUsed / data.diskTotalBytes) * 100).toFixed(0)}%)`
      : "";
  return (
    <div>
      {!data.scraped && <NotScraped what="this builder's node-exporter" />}
      <div className={styles.statGrid}>
        <Stat
          label="Load (1m / 5m / 15m)"
          value={`${fmtFloat(data.load1)} / ${fmtFloat(
            data.load5,
          )} / ${fmtFloat(data.load15)}`}
        />
        <Stat label="CPUs" value={fmtNum(data.cpuCount)} />
        <Stat
          label="Memory used"
          value={`${fmtBytes(data.memUsedBytes)} / ${fmtBytes(
            data.memTotalBytes,
          )}${memUsedPct}`}
        />
        <Stat
          label="Disk used (/)"
          value={`${fmtBytes(diskUsed)} / ${fmtBytes(
            data.diskTotalBytes,
          )}${diskUsedPct}`}
        />
      </div>
    </div>
  );
};

const builderMetadata = (builder: MonitoringBuilder): string => {
  const systems = builder.systems.join(", ");
  const jobs =
    builder.maxJobs > 0
      ? `${builder.maxJobs} ${builder.maxJobs === 1 ? "job" : "jobs"}`
      : "";
  return [systems, jobs].filter(Boolean).join(" · ");
};

const builderAnchor = (name: string): string =>
  `builder-${name.toLowerCase().replace(/[^a-z0-9]/g, "-")}`;

export const BuildersSection = ({ data }: { data: MonitoringBuilder[] }) => (
  <>
    <Text type="h2" className={styles.h2}>
      Builders
    </Text>
    <div className={styles.builderList}>
      {data.map((builder) => (
        <div
          className={styles.builder}
          id={builderAnchor(builder.name)}
          key={builder.name}
        >
          <div className={styles.builderHeader}>
            <Text type="h3" className={styles.builderName}>
              {builder.name}
            </Text>
            {builderMetadata(builder) && (
              <Text type="span" className={styles.builderMeta}>
                {builderMetadata(builder)}
              </Text>
            )}
          </div>
          <BuilderStats data={builder.stats} />
        </div>
      ))}
    </div>
  </>
);

const JobsSection = ({ data }: { data: MonitoringJobs }) => (
  <>
    <Text type="h2" className={styles.h2}>
      Jobs
    </Text>
    <div className={styles.statGrid}>
      <Stat label="Running builds" value={fmtNum(data.runningBuilds)} />
      <Stat label="Pending builds" value={fmtNum(data.pendingBuilds)} />
      <Stat label="Running actions/deploys" value={fmtNum(data.runningRuns)} />
      <Stat label="Pending actions/deploys" value={fmtNum(data.pendingRuns)} />
    </div>
    <Text type="h3" className={styles.h3}>
      Recent builds
    </Text>
    <Table className={styles.table}>
      <thead>
        <tr>
          <th>Package</th>
          <th>Status</th>
          <th>Duration</th>
        </tr>
      </thead>
      <tbody>
        {data.recentBuilds.length === 0 ? (
          <tr>
            <td colSpan={3}>
              <Text className={styles.help}>No finished builds yet.</Text>
            </td>
          </tr>
        ) : (
          data.recentBuilds.map((b, i) => (
            <tr key={`${b.name}-${i}`}>
              <td>{b.name}</td>
              <td>{b.status ?? "—"}</td>
              <td>{fmtDuration(b.durationSecs)}</td>
            </tr>
          ))
        )}
      </tbody>
    </Table>
  </>
);

const DeploymentsSection = () => {
  const servers = useLoading(getRunningServers, { poll: fromSecs(10) });
  return (
    <>
      <Text type="h2" className={styles.h2}>
        Deployments
      </Text>
      <Table className={styles.table}>
        <thead>
          <tr>
            <th>Repo</th>
            <th>Package</th>
            <th>Status</th>
            <th>Address</th>
          </tr>
        </thead>
        <tbody>
          {match(servers)
            .with({ loading: true }, () => (
              <tr>
                <td colSpan={4}>
                  <Loading />
                </td>
              </tr>
            ))
            .with({ data: Err(P.select()) }, (error) => (
              <tr>
                <td colSpan={4}>
                  <Text className={styles.error}>
                    Sorry, there was an error! ({error.message})
                  </Text>
                </td>
              </tr>
            ))
            .with({ data: Ok(P.select()) }, (list) =>
              list.length === 0 ? (
                <tr>
                  <td colSpan={4}>
                    <Text className={styles.help}>
                      No deployments running.
                    </Text>
                  </td>
                </tr>
              ) : (
                <>
                  {list.map((s) => (
                    <tr key={s.id}>
                      <td>
                        <Link
                          href={`https://github.com/${s.repo_owner}/${s.repo_name}`}
                        >
                          {s.repo_owner}/{s.repo_name}
                        </Link>
                      </td>
                      <td>{s.package_name}</td>
                      <td>{s.status}</td>
                      <td>
                        {s.ipv4 ? (
                          <Link href={s.url}>{s.ipv4}</Link>
                        ) : (
                          <Link href={s.url}>{s.url}</Link>
                        )}
                      </td>
                    </tr>
                  ))}
                </>
              ),
            )
            .exhaustive()}
        </tbody>
      </Table>
    </>
  );
};

// -- page ---------------------------------------------------------------------

const Content = ({ data }: { data: Monitoring }) => (
  <>
    <div className={styles.section}>
      <InstanceSection data={data.instance} />
    </div>
    <div className={styles.section}>
      <BuildersSection data={data.builders} />
    </div>
    <div className={styles.section}>
      <JobsSection data={data.jobs} />
    </div>
    <div className={styles.section}>
      <DeploymentsSection />
    </div>
  </>
);

const Page = () => {
  const { selfHostMode } = useConfig();
  const monitoring = useLoading(getMonitoring, { poll: fromSecs(5) });
  return (
    <div className={styles.container}>
      <Text type="h1" className={styles.h1}>
        Monitoring
      </Text>
      {!selfHostMode ? (
        <div className={styles.section}>
          <Text className={styles.help}>
            Monitoring is only available in self-host mode.
          </Text>
        </div>
      ) : (
        match(monitoring)
          .with({ loading: true }, () => (
            <div className={styles.section}>
              <Loading />
            </div>
          ))
          .with({ data: Err(P.select()) }, (error) => (
            <div className={styles.section}>
              <Text className={styles.error}>
                Sorry, there was an error! ({error.message})
              </Text>
            </div>
          ))
          .with({ data: Ok(P.select()) }, (data) => <Content data={data} />)
          .exhaustive()
      )}
    </div>
  );
};

export default AppPage(Page, { requireAuth: true });
