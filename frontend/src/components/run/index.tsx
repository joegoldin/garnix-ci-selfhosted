import Image from "next/image";
import React from "react";
import { StatusIcon } from "@/components/statusIcon";
import { Text } from "@/components/text";
import { formatCommitSha, formatRunName } from "@/utils/format";
import branchIcon from "@/components/icons/branch.svg";
import commitIcon from "@/components/icons/commit.svg";
import repoIcon from "@/components/icons/repo.svg";
import stopwatchIcon from "@/components/icons/stopwatch.svg";
import statusIcon from "@/components/icons/status.svg";
import { Link } from "@/components/link";
import { ElapsedTime } from "@/components/elapsedTime";
import { Run, cancelRun } from "@/services/run";
import { trackSubmit } from "@/utils/analytics";
import { ConfirmActionButton } from "@/components/confirmActionButton";
import { RunLog } from "../buildLog";
import { WaitingOn } from "../waitingOn";
import styles from "./styles.module.css";

const createHeaderProps = (module: Run) => {
  return [
    {
      icon: repoIcon,
      label: "Repo",
      url: `/repo/${module.repoUser}/${module.repoName}`,
      value: `${module.repoUser}/${module.repoName}`,
    },
    {
      icon: branchIcon,
      label: "Branch",
      value: module.branch,
    },
    {
      icon: commitIcon,
      label: "Commit",
      url: `/commit/${module.git_commit}`,
      value: formatCommitSha(module),
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

export const RunPage = ({
  run,
  onChanged,
}: {
  run: Run;
  onChanged?: () => void;
}) => {
  const cancel = async () => {
    trackSubmit("cancel-run");
    await cancelRun(run.id);
    onChanged?.();
  };
  return (
    <main className={styles.container}>
      <>
        <div className={styles.titleRow}>
          <Text type="h1" className={styles.h1}>
            {formatRunName(run)}
          </Text>
          {run.status === "Pending" || run.status === "Running" ? (
            <ConfirmActionButton
              triggerLabel="Cancel run"
              title="Cancel this run?"
              description={
                <p>
                  The run will be stopped and cannot be resumed. This cannot be
                  undone.
                </p>
              }
              confirmLabel="Yes, cancel run"
              onConfirm={cancel}
            />
          ) : null}
        </div>
        <div className={`${styles.section} ${styles.summary}`}>
          {createHeaderProps(run).map(({ icon, label, url, value }) => (
            <div key={label} className={styles.field}>
              <label className={styles.label}>
                <Image src={icon} alt={label} />{" "}
                <Text className={styles.labelText}>{label}</Text>
              </label>
              <Text className={styles.value}>
                {url ? <Link href={url}>{value}</Link> : value}
              </Text>
            </div>
          ))}
        </div>
        {run.waitingOn.length > 0 ? (
          <div className={styles.section}>
            <WaitingOn nodes={run.waitingOn} />
          </div>
        ) : null}
        <div className={styles.section}>
          <Text type="h2" className={styles.h2}>
            Logs
          </Text>
          <RunLog runId={run.id} />
        </div>
      </>
    </main>
  );
};
