"use client";

import React from "react";
import { useSearchParams } from "next/navigation";
import { WithSidebar } from "@/components/withSidebar";
import { Text } from "@/components/text";
import { Link } from "@/components/link";
import { Loading } from "@/components/loading";
import { DownloadIcon } from "@/components/icons/download";
import { useLoading } from "@/hooks/useLoading";
import { formatBytes, formatCommitSha, formatDateTime } from "@/utils/format";
import {
  Artifact,
  artifactManifestUrl,
  artifactZipUrl,
  getCommitArtifacts,
  getRepoArtifacts,
} from "@/services/artifacts";
import styles from "./styles.module.css";

const Page = ({ params }: { params: { owner: string; repo: string } }) => {
  const searchParams = useSearchParams();
  const commitFilter = searchParams.get("commit");

  const loadArtifacts = React.useCallback(
    () =>
      commitFilter
        ? getCommitArtifacts(params.owner, params.repo, commitFilter)
        : getRepoArtifacts(params.owner, params.repo),
    [params.owner, params.repo, commitFilter],
  );
  const artifacts = useLoading(loadArtifacts);

  return (
    <WithSidebar>
      <main className={styles.container}>
        <div className={styles.header}>
          <Text type="h1" className={styles.h1}>
            Artifacts
          </Text>
        </div>
        {commitFilter && (
          <div className={styles.filterChip}>
            <Text>
              Filtered to commit{" "}
              <code className={styles.filterChipCode}>
                {formatCommitSha({ gitCommit: commitFilter })}
              </code>
            </Text>
            <Link href={`/repo/${params.owner}/${params.repo}/artifacts`}>
              Clear
            </Link>
          </div>
        )}
        {artifacts.loading ? (
          <Loading />
        ) : !artifacts.data.ok ? (
          <EmptyState
            title="Artifacts not enabled"
            body="This server has no artifact storage configured, or you don't have access to this repo's artifacts."
          />
        ) : artifacts.data.data.length === 0 ? (
          <EmptyState
            title="No artifacts"
            body={
              commitFilter
                ? "No published artifacts for this commit."
                : "No published artifacts for this repo yet."
            }
          />
        ) : (
          <ul className={styles.artifactList}>
            {artifacts.data.data.map((artifact) => (
              <ArtifactRow key={artifact.id} artifact={artifact} />
            ))}
          </ul>
        )}
      </main>
    </WithSidebar>
  );
};

const EmptyState = ({ title, body }: { title: string; body: string }) => (
  <div className={styles.empty}>
    <Text type="h2" className={styles.h2}>
      {title}
    </Text>
    <Text>{body}</Text>
  </div>
);

const ArtifactRow = ({ artifact }: { artifact: Artifact }) => {
  const failed = artifact.status === "failed";
  return (
    <li className={styles.artifact}>
      <div className={styles.artifactRow}>
        <div className={styles.artifactMain}>
          <span className={styles.artifactName}>{artifact.name}</span>
          <Link
            href={`/build/${artifact.build_id}`}
            className={styles.artifactBuildLink}
          >
            build {artifact.build_id}
          </Link>
          {artifact.branch && (
            <span className={styles.artifactBranch}>{artifact.branch}</span>
          )}
        </div>
        {failed ? (
          <span className={styles.failedChip}>publish failed</span>
        ) : (
          <>
            <span className={styles.artifactMeta}>
              {formatBytes(artifact.total_size)} · {artifact.file_count}{" "}
              {artifact.file_count === 1 ? "file" : "files"} ·{" "}
              {formatDateTime(artifact.created_at)}
            </span>
            <span className={styles.artifactActions}>
              <Link
                href={`/build/${artifact.build_id}#artifacts`}
                className={styles.artifactBtn}
              >
                Browse files
              </Link>
              <Link
                href={artifactManifestUrl(artifact.build_id, artifact.name)}
                target="_blank"
                className={styles.artifactBtn}
              >
                Manifest
              </Link>
              <Link
                href={artifactZipUrl(artifact.build_id, artifact.name)}
                target="_blank"
                className={styles.artifactDownload}
              >
                <DownloadIcon width={13} fill="currentColor" /> Download .zip
              </Link>
            </span>
          </>
        )}
      </div>
    </li>
  );
};

export default Page;
