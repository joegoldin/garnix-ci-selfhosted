"use client";

import { useCallback, useState, type MouseEvent } from "react";
import { P, match } from "ts-pattern";
import { Text } from "@/components/text";
import { Link } from "@/components/link";
import { Loading } from "@/components/loading";
import { AppPage } from "@/utils/appPage";
import { useLoading } from "@/hooks/useLoading";
import { diffTime, formatDurationShort, fromSecs, toSecs } from "@/utils/duration";
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

// One plotted sample: a value at a point in time.
type SparklinePoint = { time: Date; value: number };

// A tiny dependency-free SVG sparkline. `points` are plotted left-to-right
// (oldest-first); the y-axis is fixed 0..max so CPU% and memory% read at a
// consistent scale as new samples stream in. A light x-axis (3-5
// time-of-day ticks, overlaid as HTML below the SVG) and a hover
// tooltip + guideline (mouse x -> nearest sample) make individual samples
// readable.
const Sparkline = ({
  points,
  max,
  color,
  formatValue,
}: {
  points: SparklinePoint[];
  max: number;
  color: string;
  formatValue: (value: number) => string;
}) => {
  const [hoverIndex, setHoverIndex] = useState<number | null>(null);

  if (points.length === 0) {
    return <div className={styles.sparkEmpty}>No samples yet.</div>;
  }
  const width = 600;
  const height = 100;
  const pad = 6;
  const n = points.length;
  const stepX = n > 1 ? (width - pad * 2) / (n - 1) : 0;
  const xForIndex = (i: number) => pad + i * stepX;
  const clamp = (v: number) => Math.max(0, Math.min(v, max));
  const scaleY = (v: number) =>
    height - pad - (clamp(v) / max) * (height - pad * 2);
  const linePoints = points
    .map((p, i) => `${xForIndex(i)},${scaleY(p.value)}`)
    .join(" ");
  const areaPoints = `${pad},${height - pad} ${linePoints} ${xForIndex(
    n - 1,
  )},${height - pad}`;

  // 3-5 evenly-spaced tick labels across the time axis, always including the
  // first and last sample.
  const tickCount = Math.min(5, n);
  const tickIndexes = Array.from(
    new Set(
      Array.from({ length: tickCount }, (_, i) =>
        tickCount === 1 ? 0 : Math.round((i * (n - 1)) / (tickCount - 1)),
      ),
    ),
  );

  const handleMouseMove = (e: MouseEvent<HTMLDivElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    if (rect.width === 0) return;
    const svgX = ((e.clientX - rect.left) / rect.width) * width;
    const index = n > 1 ? Math.round((svgX - pad) / stepX) : 0;
    setHoverIndex(Math.max(0, Math.min(n - 1, index)));
  };
  const handleMouseLeave = () => setHoverIndex(null);

  const hovered = hoverIndex != null ? points[hoverIndex] : null;

  return (
    <div
      className={styles.sparklineWrap}
      onMouseMove={handleMouseMove}
      onMouseLeave={handleMouseLeave}
    >
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
        {hoverIndex != null && (
          <line
            className={styles.sparklineGuideline}
            x1={xForIndex(hoverIndex)}
            x2={xForIndex(hoverIndex)}
            y1={pad}
            y2={height - pad}
            vectorEffect="non-scaling-stroke"
          />
        )}
      </svg>
      <div className={styles.sparklineAxis}>
        {tickIndexes.map((i) => (
          <span
            key={i}
            className={styles.sparklineTick}
            style={{ left: `${(xForIndex(i) / width) * 100}%` }}
          >
            {points[i]!.time.toLocaleTimeString([], {
              hour: "2-digit",
              minute: "2-digit",
            })}
          </span>
        ))}
      </div>
      {hovered != null && (
        <div
          className={styles.sparklineTooltip}
          style={{ left: `${(xForIndex(hoverIndex!) / width) * 100}%` }}
        >
          <div>{hovered.time.toLocaleTimeString()}</div>
          <div>{formatValue(hovered.value)}</div>
        </div>
      )}
    </div>
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
  points,
  color,
  formatValue,
}: {
  title: string;
  current: string;
  points: SparklinePoint[];
  color: string;
  formatValue: (value: number) => string;
}) => (
  <div className={styles.chartBlock}>
    <div className={styles.chartHeader}>
      <Text type="span" className={styles.chartTitle}>
        {title}
      </Text>
      <span className={styles.chartCurrent}>{current}</span>
    </div>
    <Sparkline
      points={points}
      max={100}
      color={color}
      formatValue={formatValue}
    />
  </div>
);

// The threshold past which the reporter's latest sample is considered stale:
// the guest pushes best-effort every ~20s with errors swallowed, so a
// redeployed or egress-broken guest silently stops reporting. 90s is a few
// missed pushes' worth of slack before flagging it.
const STALE_AFTER_SECS = 90;

const ReporterStaleness = ({ sampledAt }: { sampledAt: Date }) => {
  const age = diffTime(new Date(), sampledAt);
  const stale = toSecs(age) > STALE_AFTER_SECS;
  return stale ? (
    <Text
      type="p"
      className={`${styles.staleness} ${styles.staleWarning}`}
    >
      ⚠ reporter stale — last sample {formatDurationShort(age)} ago
    </Text>
  ) : (
    <Text type="p" className={`${styles.staleness} ${styles.staleLive}`}>
      ● live
    </Text>
  );
};

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
  const cpuPoints: SparklinePoint[] = samples.map((s) => ({
    time: s.sampled_at,
    value: s.cpu_pct,
  }));
  const ramPoints: SparklinePoint[] = samples.map((s) => ({
    time: s.sampled_at,
    value: memPctOf(s.mem_used_kb, s.mem_total_kb),
  }));
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
          points={cpuPoints}
          color="#2f855a"
          formatValue={(v) => `${v.toFixed(1)}%`}
        />
        <ChartBlock
          title="Memory utilisation"
          current={`${memPct}%`}
          points={ramPoints}
          color="#2b6cb0"
          formatValue={(v) => `${Math.round(v)}%`}
        />
      </div>
    </>
  );
};

const Page = ({ params }: { params: Record<string, string> }) => {
  const id = params.id!;
  const stats = useLoading(
    useCallback(() => getServerStats(id), [id]),
    { poll: fromSecs(5) },
  );
  const serverResult = useLoading(getRunningServers, { poll: fromSecs(10) });
  const server =
    !serverResult.loading && serverResult.data.ok
      ? serverResult.data.data.find((s) => s.id === id) ?? null
      : null;
  const currentSample =
    !stats.loading && stats.data.ok ? stats.data.data.current : null;
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
      {currentSample ? (
        <ReporterStaleness sampledAt={currentSample.sampled_at} />
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
