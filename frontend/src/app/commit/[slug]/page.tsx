"use client";

import React from "react";
import { P, match } from "ts-pattern";
import { CommitBuildsSummary } from "@/components/build";
import { StatusIcon } from "@/components/statusIcon";
import { Text } from "@/components/text";
import { Link } from "@/components/link";
import { Button } from "@/components/button";
import { FloatingModal, ModalActions, ModalSection } from "@/components/modal";
import { formatCommitSha, formatRunName, runUrl } from "@/utils/format";
import { useLoading } from "@/hooks/useLoading";
import { BuildStatus } from "@/services/build";
import { Err, Ok } from "@/services";
import { fromSecs } from "@/utils/duration";
import { getCommit, cancelCommit } from "@/services/commit";
import styles from "./styles.module.css";

const Page = ({ params }: { params: { slug: string } }) => {
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
  if (commit.loading) return null;
  const reloadCommit = commit.reload;
  return (
    <main className={styles.container}>
      {match(commit.data)
        .with(Ok(P.select()), (commit) => {
          return (
            <>
              <div className={styles.header}>
                <Text type="h1" className={styles.h1}>
                  Commit [{formatCommitSha(commit.summary)}]
                </Text>
                {commit.summary.pending + commit.summary.running > 0 && (
                  <CancelAllButton
                    slug={params.slug}
                    pendingCount={commit.summary.pending + commit.summary.running}
                    reload={reloadCommit}
                  />
                )}
              </div>
              <CommitBuildsSummary commit={commit.summary} />
            <div className={styles.modules}>
              {(() => {
                const runningIds = new Set(commit.running_build_ids);
                return [...commit.builds, ...commit.runs].map((build) => {
                  const status =
                    build.status === "Pending" && runningIds.has(build.id)
                      ? ("Running" as const)
                      : build.status;
                  return (
                    <Link
                      key={build.id}
                      href={runUrl(build)}
                      variant="wrapper"
                    >
                      <div className={styles.module}>
                        <Text>{formatRunName(build)}</Text>
                        <div className={styles.status}>
                          <StatusIcon status={status} />
                          <Text className={styles.statusText}>
                            {getStatusText(status)}
                          </Text>
                        </div>
                      </div>
                    </Link>
                  );
                });
              })()}
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
    await cancelCommit(slug);
    setBusy(false);
    setOpen(false);
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
            <p className={styles.modalText}>
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

const getStatusText = (status: BuildStatus): string => {
  if (status === "Failure") return "Failed";
  else return status;
};

export default Page;
