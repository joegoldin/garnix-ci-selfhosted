"use client";

import React from "react";
import { P, match } from "ts-pattern";
import { CommitBuildsSummary } from "@/components/build";
import { StatusIcon } from "@/components/statusIcon";
import { ArtifactIcon } from "@/components/icons/artifact";
import { Text } from "@/components/text";
import { Link } from "@/components/link";
import { Button } from "@/components/button";
import { Select } from "@/components/select";
import { FloatingModal, ModalActions, ModalSection } from "@/components/modal";
import { formatCommitSha, formatRunName, runUrl } from "@/utils/format";
import { useLoading } from "@/hooks/useLoading";
import { BuildStatus } from "@/services/build";
import { Err, Ok } from "@/services";
import { fromSecs } from "@/utils/duration";
import { Berlin } from "@/utils/fonts";
import {
  getCommit,
  cancelCommit,
  restartFailedCommit,
} from "@/services/commit";
import { getCommitArtifacts } from "@/services/artifacts";
import styles from "./styles.module.css";

// Buckets the row status filter groups statuses into. "All" shows
// everything; the others partition the terminal + in-progress statuses.
type StatusFilter = "All" | "Active" | "Complete" | "Failed";

const matchesStatusFilter = (
  filter: StatusFilter,
  status: BuildStatus,
): boolean => {
  switch (filter) {
    case "All":
      return true;
    case "Active":
      return status === "Pending" || status === "Running";
    case "Complete":
      return status === "Success" || status === "Skipped";
    case "Failed":
      return (
        status === "Failure" || status === "Timeout" || status === "Cancelled"
      );
  }
};

// Row background accent by status: red for failed/timed-out/cancelled, green
// for running, orange for pending, and no tint for completed rows.
const moduleStatusClass = (status: BuildStatus): string => {
  if (status === "Failure" || status === "Timeout" || status === "Cancelled")
    return styles.moduleFailed ?? "";
  if (status === "Running") return styles.moduleRunning ?? "";
  if (status === "Pending") return styles.modulePending ?? "";
  return ""; // Success, skipped, and anything else: no tint
};

const Page = ({ params }: { params: { slug: string } }) => {
  const [statusFilter, setStatusFilter] = React.useState<StatusFilter>("All");
  const commit = useLoading(
    React.useCallback(() => getCommit(params.slug), [params.slug]),
    {
      poll: fromSecs(5),
      shouldPoll: (result) =>
        match(result)
          .with(Err(P._), () => true)
          .with(
            Ok({ summary: P.select() }),
            (summary) => summary.pending + summary.running > 0,
          )
          .exhaustive(),
    },
  );
  // Artifact counts per build for this commit, so package rows can show an
  // artifact icon (only `Build` rows can have artifacts; `Run` rows -
  // actions, deployments, etc. - aren't linked to the `artifacts` table).
  // Tolerates a 404 (no artifact store configured) by showing no icons.
  const repoOwner =
    !commit.loading && commit.data.ok ? commit.data.data.summary.repoUser : null;
  const repoName =
    !commit.loading && commit.data.ok ? commit.data.data.summary.repoName : null;
  const loadArtifactCounts = React.useCallback(
    () =>
      repoOwner && repoName
        ? getCommitArtifacts(repoOwner, repoName, params.slug).then((result) =>
            result.ok
              ? result.data.reduce<Record<string, number>>((acc, artifact) => {
                  acc[artifact.build_id] = (acc[artifact.build_id] ?? 0) + 1;
                  return acc;
                }, {})
              : {},
          )
        : Promise.resolve({} as Record<string, number>),
    [repoOwner, repoName, params.slug],
  );
  const artifactCounts = useLoading(loadArtifactCounts);
  const artifactCountByBuildId = artifactCounts.loading ? {} : artifactCounts.data;

  if (commit.loading) return null;
  const reloadCommit = commit.reload;
  return (
    <main className={styles.container}>
      {match(commit.data)
        .with(Ok(P.select()), (commit) => {
          const runningIds = new Set(commit.running_build_ids);
          const rows = [...commit.builds, ...commit.runs].map((build) => {
            const status =
              build.status === "Pending" && runningIds.has(build.id)
                ? ("Running" as const)
                : build.status;
            return { build, status };
          });
          // Disable a bucket when no row matches it (All is always enabled).
          const filterOptions = (
            ["All", "Active", "Complete", "Failed"] as const
          ).map(
            (f): readonly [StatusFilter, string, boolean] => [
              f,
              f,
              f !== "All" &&
                !rows.some(({ status }) => matchesStatusFilter(f, status)),
            ],
          );
          const visibleRows = rows.filter(({ status }) =>
            matchesStatusFilter(statusFilter, status),
          );
          const artifactTotal = Object.values(artifactCountByBuildId).reduce(
            (sum, n) => sum + n,
            0,
          );
          return (
            <>
              <div className={styles.header}>
                <div className={styles.headerLeft}>
                  <Text type="h1" className={styles.h1}>
                    Commit [{formatCommitSha(commit.summary)}]
                  </Text>
                  <Select
                    value={statusFilter}
                    onChange={setStatusFilter}
                    options={filterOptions}
                  />
                  {artifactTotal > 0 && (
                    <Link
                      href={`/repo/${commit.summary.repoUser}/${commit.summary.repoName}/artifacts?commit=${params.slug}`}
                      className={styles.headerArtifactBadge}
                    >
                      <ArtifactIcon width={14} height={14} />
                      {artifactTotal} artifact{artifactTotal === 1 ? "" : "s"}
                    </Link>
                  )}
                </div>
                <div className={styles.headerActions}>
                  {commit.summary.failed > 0 && (
                    <RestartFailedButton
                      slug={params.slug}
                      failedCount={commit.summary.failed}
                      reload={reloadCommit}
                    />
                  )}
                  {commit.summary.pending + commit.summary.running > 0 && (
                    <CancelAllButton
                      slug={params.slug}
                      pendingCount={
                        commit.summary.pending + commit.summary.running
                      }
                      reload={reloadCommit}
                    />
                  )}
                </div>
              </div>
              <CommitBuildsSummary commit={commit.summary} />
              <div className={styles.modules}>
                {visibleRows.map(({ build, status }) => {
                  // Only `Build` rows (packages) can have artifacts.
                  const artifactCount =
                    build.tag === "Build"
                      ? artifactCountByBuildId[build.id]
                      : undefined;
                  const href =
                    artifactCount != null && artifactCount > 0
                      ? `${runUrl(build)}#artifacts`
                      : runUrl(build);
                  return (
                    <Link key={build.id} href={href} variant="wrapper">
                      <div
                        className={`${styles.module} ${moduleStatusClass(status)}`}
                      >
                        <div className={styles.moduleName}>
                          <Text>{formatRunName(build)}</Text>
                          {artifactCount != null && artifactCount > 0 && (
                            <span
                              className={styles.artifactBadge}
                              title={`${artifactCount} artifact${artifactCount === 1 ? "" : "s"}`}
                            >
                              <ArtifactIcon width={12} height={12} />
                              {artifactCount}
                            </span>
                          )}
                        </div>
                        <div className={styles.status}>
                          <StatusIcon status={status} />
                          <Text className={styles.statusText}>
                            {getStatusText(status)}
                          </Text>
                        </div>
                      </div>
                    </Link>
                  );
                })}
              </div>
            </>
          );
        })
        .with(Err(P._), () => (
          <Text>
            Uh oh! No build matching that description could be found. Either it
            doesn&apos;t exist, or you don&apos;t have access to it.
          </Text>
        ))
        .exhaustive()}
    </main>
  );
};

const CancelAllButton = ({
  slug,
  pendingCount,
  reload,
}: {
  slug: string;
  pendingCount: number;
  reload: () => void;
}) => {
  const [open, setOpen] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const cancelAll = async () => {
    setBusy(true);
    try {
      await cancelCommit(slug);
    } finally {
      setBusy(false);
      setOpen(false);
    }
    reload();
  };
  const count = pendingCount;
  return (
    <>
      <Button style="warning" onClick={() => setOpen(true)}>
        Cancel all
      </Button>
      {open && (
        <FloatingModal onRequestClose={() => setOpen(false)}>
          <ModalSection>
            <Text type="h1">Cancel all in-progress builds?</Text>
          </ModalSection>
          <ModalSection>
            <p className={`${styles.modalText} ${Berlin.className}`}>
              This will cancel {count} in-progress build
              {count === 1 ? "" : "s"} for this commit. This cannot be undone.
            </p>
          </ModalSection>
          <ModalSection>
            <ModalActions align="right">
              <Button onClick={() => setOpen(false)}>Nevermind</Button>
              <Button style="warning" loading={busy} onClick={cancelAll}>
                Cancel all builds
              </Button>
            </ModalActions>
          </ModalSection>
        </FloatingModal>
      )}
    </>
  );
};

const RestartFailedButton = ({
  slug,
  failedCount,
  reload,
}: {
  slug: string;
  failedCount: number;
  reload: () => void;
}) => {
  const [open, setOpen] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const restartFailed = async () => {
    setBusy(true);
    try {
      await restartFailedCommit(slug);
    } finally {
      setBusy(false);
      setOpen(false);
    }
    reload();
  };
  return (
    <>
      <Button onClick={() => setOpen(true)}>Restart failed</Button>
      {open && (
        <FloatingModal onRequestClose={() => setOpen(false)}>
          <ModalSection>
            <Text type="h1">Restart failed builds?</Text>
          </ModalSection>
          <ModalSection>
            <p className={`${styles.modalText} ${Berlin.className}`}>
              This will restart {failedCount} failed build
              {failedCount === 1 ? "" : "s"} for this commit.
            </p>
          </ModalSection>
          <ModalSection>
            <ModalActions align="right">
              <Button onClick={() => setOpen(false)}>Nevermind</Button>
              <Button loading={busy} onClick={restartFailed}>
                Restart failed builds
              </Button>
            </ModalActions>
          </ModalSection>
        </FloatingModal>
      )}
    </>
  );
};

const getStatusText = (status: BuildStatus): string => {
  if (status === "Failure") return "Failed";
  else return status;
};

export default Page;
