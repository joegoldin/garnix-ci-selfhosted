"use client";

import Image from "next/image";
import { useCallback } from "react";
import React from "react";
import { P, match } from "ts-pattern";
import { z } from "zod";
import { BuildLog } from "@/components/buildLog";
import { WaitingOn } from "@/components/waitingOn";
import { Button } from "@/components/button";
import { StatusIcon } from "@/components/statusIcon";
import { Text } from "@/components/text";
import { Loading } from "@/components/loading";
import {
  formatBytes,
  formatCommitSha,
  formatDateTime,
  formatRunName,
} from "@/utils/format";
import branchIcon from "@/components/icons/branch.svg";
import commitIcon from "@/components/icons/commit.svg";
import repoIcon from "@/components/icons/repo.svg";
import clockIcon from "@/components/icons/clock.svg";
import stopwatchIcon from "@/components/icons/stopwatch.svg";
import folderIcon from "@/components/icons/folder.svg";
import cubeIcon from "@/components/icons/cube.svg";
import terminalIcon from "@/components/icons/terminal.svg";
import statusIcon from "@/components/icons/status.svg";
import { DownloadIcon } from "@/components/icons/download";
import { ArtifactIcon } from "@/components/icons/artifact";
import { Build, getBuild } from "@/services/build";
import { Link } from "@/components/link";
import { forgeBranchUrl } from "@/utils/forge";
import { useConfig } from "@/store/configContext";
import { useLoading } from "@/hooks/useLoading";
import { fromSecs } from "@/utils/duration";
import { ElapsedTime } from "@/components/elapsedTime";
import { APIResult, Err, Ok, fetchFromAPI } from "@/services";
import { useForm } from "@/hooks/useForm";
import { cancelBuild } from "@/services/build";
import {
  Artifact,
  ArtifactManifest,
  artifactFileUrl,
  artifactLatestZipUrl,
  artifactZipUrl,
  getArtifactManifest,
  getBuildArtifacts,
  lockBuildArtifacts,
  unlockBuildArtifacts,
} from "@/services/artifacts";
import { trackSubmit } from "@/utils/analytics";
import styles from "./styles.module.css";

const createHeaderProps = (module: Build, giteaUrl: string) => {
  return [
    {
      icon: repoIcon,
      label: "Repo",
      url: `/repo/${module.repoUser}/${module.repoName}`,
      external: false,
      value: `${module.repoUser}/${module.repoName}`,
    },
    {
      icon: branchIcon,
      label: "Branch",
      // No garnix branch page exists, so link out to the forge branch.
      url: module.branch
        ? forgeBranchUrl(
            module.forge,
            giteaUrl,
            module.repoUser,
            module.repoName,
            module.branch,
          )
        : undefined,
      external: true,
      value: module.branch,
    },
    {
      icon: commitIcon,
      label: "Commit",
      url: `/commit/${module.git_commit}`,
      external: false,
      value: formatCommitSha(module),
    },
    {
      icon: clockIcon,
      label: "Started at",
      value: formatDateTime(module.startTime),
    },
    {
      icon: stopwatchIcon,
      label: "Total time",
      value: (
        <ElapsedTime
          start={module.startTime}
          end={module.endTime}
          running={module.status === "Running"}
        />
      ),
    },
    {
      icon: folderIcon,
      label: "Type",
      value: formatPackageType(module.packageType),
    },
    {
      icon: cubeIcon,
      label: "Package",
      value: module.package,
    },
    {
      icon: terminalIcon,
      label: "System",
      value: module.system || "-",
    },
    {
      icon: clockIcon,
      label: "Finished at",
      value: formatDateTime(module.endTime),
    },
    {
      icon: statusIcon,
      label: "Status",
      value: (
        <span className={styles.status}>
          <StatusIcon status={module.status} /> {module.status}
        </span>
      ),
    },
  ];
};

const Page = ({ params }: { params: { slug: string } }) => {
  const { giteaUrl } = useConfig();
  const build = useLoading(
    useCallback(() => getBuild(params.slug), [params.slug]),
    {
      poll: fromSecs(5),
      shouldPoll: (result) =>
        match(result)
          .with(Err(P._), () => true)
          .with(Ok({ status: "Pending" }), () => true)
          .with(Ok({ status: "Running" }), () => true)
          .with(Ok(P._), () => false)
          .exhaustive(),
    },
  );
  const form = useForm({}, async () => {
    trackSubmit("cancel-build");
    await cancelBuild(params.slug);
    build.reload();
    return Ok(null);
  });

  if (build.loading) return null;
  return (
    <main className={styles.container}>
      {match(build.data)
        .with(Ok(P.select()), (build) => (
          <>
            <div className={styles.titleRow}>
              <Text type="h1" className={styles.h1}>
                {formatRunName(build)}
              </Text>
              <div className={styles.titleActions}>
                <BuildArtifactBadge buildId={params.slug} />
                {build.status === "Pending" || build.status === "Running" ? (
                  <form {...form.props}>
                    <Button submit={true} style="warning">
                      Cancel build
                    </Button>
                  </form>
                ) : null}
              </div>
            </div>
            <div className={`${styles.section} ${styles.summary}`}>
              {createHeaderProps(build, giteaUrl).map(
                ({ icon, label, url, external, value }) => (
                  <div key={label} className={styles.field}>
                    <label className={styles.label}>
                      <Image src={icon} alt={label} />{" "}
                      <Text className={styles.labelText}>{label}</Text>
                    </label>
                    <Text className={styles.value}>
                      {!url ? (
                        value
                      ) : external ? (
                        <Link href={url} target="_blank" rel="noreferrer">
                          {value}
                        </Link>
                      ) : (
                        <Link href={url}>{value}</Link>
                      )}
                    </Text>
                  </div>
                ),
              )}
            </div>
            {build.waitingOn.length > 0 ? (
              <div className={styles.section}>
                <WaitingOn nodes={build.waitingOn} />
              </div>
            ) : null}
            {/* Keyed on status so artifacts refetch when the build finishes
                (they are published right after a successful build). */}
            <ArtifactsSection
              key={`artifacts-${build.status}`}
              buildId={params.slug}
            />
            <div className={styles.section}>
              <Text type="h2" className={styles.h2}>
                Logs{" "}
                <Link
                  href={`/api/build/${params.slug}/logs/raw`}
                  target="_blank"
                  className={styles.downloadLogs}
                  title="Download Raw Logs"
                >
                  <DownloadIcon width={15} fill="#d6d3d1" />
                </Link>
              </Text>
              <BuildLog build={build} />
            </div>
          </>
        ))
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

// Locking is admin-only; mirror the garnix-admin page's whoami-based check.
const whoamiSchema = z
  .object({
    username: z.string(),
    email: z.string(),
    is_admin: z.boolean(),
  })
  .nullable();

const getWhoami = () => fetchFromAPI(whoamiSchema, "GET", "whoami");

// A compact "N artifacts" chip next to the build title, deep-linking to the
// Artifacts section below, so a build's artifacts are visible at a glance
// without scrolling. Renders nothing when the build has no published artifacts
// or the artifact store isn't configured (404 -> not ok).
const BuildArtifactBadge = ({ buildId }: { buildId: string }) => {
  const artifacts = useLoading(
    useCallback(() => getBuildArtifacts(buildId), [buildId]),
  );
  if (
    artifacts.loading ||
    !artifacts.data.ok ||
    artifacts.data.data.length === 0
  )
    return null;
  const count = artifacts.data.data.length;
  return (
    <a href="#artifacts" className={styles.titleArtifactBadge}>
      <ArtifactIcon width={14} height={14} />
      {count} artifact{count === 1 ? "" : "s"}
    </a>
  );
};

const ArtifactsSection = ({ buildId }: { buildId: string }) => {
  const artifacts = useLoading(
    useCallback(() => getBuildArtifacts(buildId), [buildId]),
  );
  const whoami = useLoading(getWhoami);
  const isAdmin =
    !whoami.loading && whoami.data.ok && whoami.data.data?.is_admin === true;
  // Deep-linked from the commit page's per-row artifact icons
  // (`/build/<id>#artifacts`): once the section actually renders, jump to it
  // (the browser's own anchor-scroll fires before this async data arrives).
  React.useEffect(() => {
    if (
      !artifacts.loading &&
      artifacts.data.ok &&
      artifacts.data.data.length > 0 &&
      window.location.hash === "#artifacts"
    ) {
      document
        .getElementById("artifacts")
        ?.scrollIntoView({ block: "start" });
    }
  }, [artifacts]);
  // No artifacts (or a backend without the feature) -> no section at all.
  if (artifacts.loading || !artifacts.data.ok) return null;
  if (artifacts.data.data.length === 0) return null;
  return (
    <div className={styles.section} id="artifacts">
      <Text type="h2" className={styles.h2}>
        Artifacts
      </Text>
      <ul className={styles.artifactList}>
        {artifacts.data.data.map((artifact) => (
          <ArtifactRow
            key={artifact.id}
            buildId={buildId}
            artifact={artifact}
            isAdmin={isAdmin}
            onChanged={artifacts.reload}
          />
        ))}
      </ul>
    </div>
  );
};

const ArtifactRow = ({
  buildId,
  artifact,
  isAdmin,
  onChanged,
}: {
  buildId: string;
  artifact: Artifact;
  isAdmin: boolean;
  onChanged: () => void;
}) => {
  const [expanded, setExpanded] = React.useState(false);
  const [manifest, setManifest] =
    React.useState<APIResult<ArtifactManifest> | null>(null);
  const [busy, setBusy] = React.useState(false);
  const failed = artifact.status === "failed";
  const latestUrl = artifactLatestZipUrl(artifact);

  const toggleFiles = () => {
    setExpanded(!expanded);
    // Fetch the manifest lazily, once, on first expansion. The request
    // itself can still fail outright (offline, unexpected network error);
    // without this `.catch` that leaves `manifest` stuck at `null` forever -
    // an infinite spinner instead of an error message.
    if (manifest == null)
      void getArtifactManifest(buildId, artifact.name)
        .then(setManifest)
        .catch((error: unknown) =>
          setManifest(
            Err({
              path: `artifacts/build/${buildId}/${artifact.name}/manifest.json`,
              reason: "server-error",
              message:
                error instanceof Error
                  ? error.message
                  : "Failed to fetch the file list",
              status: 0,
            }),
          ),
        );
  };

  // Locking is build-level (it flips every artifact of the build).
  const toggleLock = async () => {
    setBusy(true);
    await (artifact.locked
      ? unlockBuildArtifacts(buildId)
      : lockBuildArtifacts(buildId));
    setBusy(false);
    onChanged();
  };

  return (
    <li className={styles.artifact}>
      <div className={styles.artifactRow}>
        <span className={styles.artifactName}>{artifact.name}</span>
        {failed ? (
          <span className={styles.failedChip}>publish failed</span>
        ) : (
          <>
            <span className={styles.artifactMeta}>
              {formatBytes(artifact.total_size)} · {artifact.file_count}{" "}
              {artifact.file_count === 1 ? "file" : "files"}
            </span>
            {artifact.locked ? (
              <span className={styles.lockedChip} title="Never reaped">
                locked
              </span>
            ) : null}
            <span className={styles.artifactActions}>
              <button
                type="button"
                className={styles.artifactBtn}
                onClick={toggleFiles}
              >
                {expanded ? "Hide files" : "Show files"}
              </button>
              {latestUrl != null ? (
                <CopyLatestUrlButton url={latestUrl} />
              ) : null}
              {isAdmin ? (
                <button
                  type="button"
                  className={styles.artifactBtn}
                  onClick={() => void toggleLock()}
                  disabled={busy}
                  title="Locked artifacts are never reaped by retention"
                >
                  {artifact.locked ? "Unlock" : "Lock"}
                </button>
              ) : null}
              <Link
                href={artifactZipUrl(buildId, artifact.name)}
                target="_blank"
                className={styles.artifactDownload}
              >
                <DownloadIcon width={13} fill="currentColor" /> Download .zip
              </Link>
            </span>
          </>
        )}
      </div>
      {!failed && expanded ? (
        <div className={styles.artifactFiles}>
          {manifest == null ? (
            <Loading />
          ) : !manifest.ok ? (
            <Text className={styles.artifactError}>
              Failed to load the file list: {manifest.error.message}
            </Text>
          ) : (
            <ul className={styles.artifactFileList}>
              {manifest.data.files.map((file) => (
                <li key={file.path} className={styles.artifactFileRow}>
                  <Link
                    href={artifactFileUrl(buildId, artifact.name, file.path)}
                    target="_blank"
                    title={`sha256: ${file.sha256}`}
                    className={styles.artifactFilePath}
                  >
                    {file.path}
                  </Link>
                  <span className={styles.artifactFileSize}>
                    {formatBytes(file.size)}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>
      ) : null}
    </li>
  );
};

// Copies the stable per-branch latest.zip URL (absolute, so it can be pasted
// into scripts). Same copy pattern as the servers page's CopyableCommand.
const CopyLatestUrlButton = ({ url }: { url: string }) => {
  const [copied, setCopied] = React.useState(false);
  return (
    <button
      type="button"
      className={styles.artifactBtn}
      title={`Copy the stable latest-artifact URL: ${url}`}
      onClick={() => {
        void navigator.clipboard?.writeText(`${window.location.origin}${url}`);
        setCopied(true);
        window.setTimeout(() => setCopied(false), 1200);
      }}
    >
      {copied ? "Copied" : "Copy latest URL"}
    </button>
  );
};

const formatPackageType = (packageType: string): string => {
  if (packageType === "nixosConfiguration") {
    return "NixOS Configuration";
  }
  return (
    packageType
      .replace(/([A-Z])/g, " $1")
      // uppercase the first character
      .replace(/^./, function (str) {
        return str.toUpperCase();
      })
  );
};

export default Page;
