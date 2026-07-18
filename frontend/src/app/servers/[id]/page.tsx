"use client";

import { useCallback } from "react";
import { P, match } from "ts-pattern";
import { Text } from "@/components/text";
import { Link } from "@/components/link";
import { Loading } from "@/components/loading";
import { AppPage } from "@/utils/appPage";
import { useLoading } from "@/hooks/useLoading";
import { fromSecs } from "@/utils/duration";
import { Err, Ok } from "@/services";
import {
  getServerStats,
  getRunningServers,
  ServerStatsHistory,
} from "@/services/servers";
import styles from "./styles.module.css";

// KiB -> GiB, one decimal.
const kbToGiB = (kb: number): string => (kb / 1024 / 1024).toFixed(1);

const memPctOf = (usedKb: number, totalKb: number): number =>
  totalKb > 0 ? Math.round((usedKb / totalKb) * 100) : 0;

// A tiny dependency-free SVG sparkline. `values` are plotted left-to-right
// (oldest-first); the y-axis is fixed 0..max so CPU% and memory% read at a
// consistent scale as new samples stream in.
const Sparkline = ({
  values,
  max,
  color,
}: {
  values: number[];
  max: number;
  color: string;
}) => {
  if (values.length === 0) {
    return <div className={styles.sparkEmpty}>No samples yet.</div>;
  }
  const width = 600;
  const height = 100;
  const pad = 6;
  const n = values.length;
  const stepX = n > 1 ? (width - pad * 2) / (n - 1) : 0;
  const clamp = (v: number) => Math.max(0, Math.min(v, max));
  const scaleY = (v: number) =>
    height - pad - (clamp(v) / max) * (height - pad * 2);
  const linePoints = values
    .map((v, i) => `${pad + i * stepX},${scaleY(v)}`)
    .join(" ");
  const areaPoints = `${pad},${height - pad} ${linePoints} ${
    pad + (n - 1) * stepX
  },${height - pad}`;
  return (
    <svg
      className={styles.sparkline}
      viewBox={`0 0 ${width} ${height}`}
      preserveAspectRatio="none"
      role="img"
      aria-hidden="true"
    >
      <polyline points={areaPoints} fill={color} fillOpacity={0.1} />
      <polyline
        points={linePoints}
        fill="none"
        stroke={color}
        strokeWidth={2}
        vectorEffect="non-scaling-stroke"
      />
    </svg>
  );
};

const StatCard = ({ label, value }: { label: string; value: string }) => (
  <div className={styles.stat}>
    <Text type="span" className={styles.statLabel}>
      {label}
    </Text>
    <Text type="span" className={styles.statValue}>
      {value}
    </Text>
  </div>
);

const ChartBlock = ({
  title,
  current,
  values,
  color,
}: {
  title: string;
  current: string;
  values: number[];
  color: string;
}) => (
  <div className={styles.chartBlock}>
    <div className={styles.chartHeader}>
      <Text type="span" className={styles.chartTitle}>
        {title}
      </Text>
      <span className={styles.chartCurrent}>{current}</span>
    </div>
    <Sparkline values={values} max={100} color={color} />
  </div>
);

const MonitorContent = ({ history }: { history: ServerStatsHistory }) => {
  const { current, samples } = history;
  if (!current && samples.length === 0) {
    return (
      <Text className={styles.help}>
        No samples yet. The server&apos;s reporter pushes CPU and memory every
        ~20s once it&apos;s deployed and running.
      </Text>
    );
  }
  const cpuValues = samples.map((s) => s.cpu_pct);
  const ramValues = samples.map((s) => memPctOf(s.mem_used_kb, s.mem_total_kb));
  const memPct = current ? memPctOf(current.mem_used_kb, current.mem_total_kb) : 0;
  return (
    <>
      <div className={styles.statGrid}>
        <StatCard
          label="CPU"
          value={current ? `${current.cpu_pct.toFixed(1)}%` : "—"}
        />
        <StatCard
          label="Memory used"
          value={
            current
              ? `${kbToGiB(current.mem_used_kb)} / ${kbToGiB(
                  current.mem_total_kb,
                )} GiB (${memPct}%)`
              : "—"
          }
        />
        <StatCard label="Samples" value={`${samples.length}`} />
        <StatCard
          label="Last update"
          value={current ? current.sampled_at.toLocaleTimeString() : "—"}
        />
      </div>
      <div className={styles.charts}>
        <ChartBlock
          title="CPU utilisation"
          current={current ? `${current.cpu_pct.toFixed(1)}%` : "—"}
          values={cpuValues}
          color="#2f855a"
        />
        <ChartBlock
          title="Memory utilisation"
          current={`${memPct}%`}
          values={ramValues}
          color="#2b6cb0"
        />
      </div>
    </>
  );
};

const Page = ({ params }: { params: { id: string } }) => {
  const stats = useLoading(
    useCallback(() => getServerStats(params.id), [params.id]),
    { poll: fromSecs(5) },
  );
  const serverResult = useLoading(getRunningServers, { poll: fromSecs(10) });
  const server =
    !serverResult.loading && serverResult.data.ok
      ? serverResult.data.data.find((s) => s.id === params.id) ?? null
      : null;
  return (
    <div className={styles.container}>
      <Link href="/servers" className={styles.back}>
        ← Servers
      </Link>
      <Text type="h1" className={styles.h1}>
        {server ? `${server.repo_owner}/${server.repo_name}` : "Server"} —
        Monitor
      </Text>
      {server ? (
        <Text type="p" className={styles.subtitle}>
          {server.package_name} · {server.status}
        </Text>
      ) : null}
      <div className={styles.section}>
        {match(stats)
          .with({ loading: true }, () => <Loading />)
          .with({ data: Err(P.select()) }, (error) => (
            <Text className={styles.error}>
              Sorry, there was an error! ({error.message})
            </Text>
          ))
          .with({ data: Ok(P.select()) }, (history) => (
            <MonitorContent history={history} />
          ))
          .exhaustive()}
      </div>
    </div>
  );
};

export default AppPage(Page, { requireAuth: true });
