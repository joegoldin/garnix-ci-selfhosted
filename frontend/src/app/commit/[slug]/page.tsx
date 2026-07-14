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
import { BuildStatus, cancelBuild } from "@/services/build";
import { Err, Ok } from "@/services";
import { fromSecs } from "@/utils/duration";
import { getCommit } from "@/services/commit";
import styles from "./styles.module.css";

const Page = ({ params }: { params: { slug: string } }) => {
  const commit = useLoading(
    React.useCallback(() => getCommit(params.slug), [params.slug]),
    {
      poll: fromSecs(5),
      shouldPoll: (result) =>
        match(result)
          .with(Err(P._), () => true)
          .with(Ok({ summary: P.select() }), (summary) => summary.pending > 0)
          .exhaustive(),
    },
  );
  if (commit.loading) return null;
  const reloadCommit = commit.reload;
  return (
    <main className={styles.container}>
      {match(commit.data)
        .with(Ok(P.select()), (commit) => {
          const pendingBuildIds = commit.builds
            .filter((build) => build.status === "Pending")
            .map((build) => build.id);
          return (
            <>
              <div className={styles.header}>
                <Text type="h1" className={styles.h1}>
                  Commit [{formatCommitSha(commit.summary)}]
                </Text>
                {pendingBuildIds.length > 0 && (
                  <CancelAllButton
                    pendingBuildIds={pendingBuildIds}
                    reload={reloadCommit}
                  />
                )}
              </div>
              <CommitBuildsSummary commit={commit.summary} />
            <div className={styles.modules}>
              {[...commit.builds, ...commit.runs].map((build) => (
                <Link key={build.id} href={runUrl(build)} variant="wrapper">
                  <div className={styles.module}>
                    <Text>{formatRunName(build)}</Text>
                    <div className={styles.status}>
                      <StatusIcon status={build.status} />
                      <Text className={styles.statusText}>
                        {getStatusText(build.status)}
                      </Text>
                    </div>
                  </div>
                </Link>
              ))}
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
  pendingBuildIds,
  reload,
}: {
  pendingBuildIds: string[];
  reload: () => void;
}) => {
  const [open, setOpen] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const cancelAll = async () => {
    setBusy(true);
    await Promise.all(pendingBuildIds.map((id) => cancelBuild(id)));
    setBusy(false);
    setOpen(false);
    reload();
  };
  const count = pendingBuildIds.length;
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
