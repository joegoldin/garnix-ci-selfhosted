import Image from "next/image";
import { ReactNode } from "react";
import { Link } from "@/components/link";
import { Text } from "@/components/text";
import { StatusIcon } from "@/components/statusIcon";
import repoIcon from "@/components/icons/repo.svg";
import branchIcon from "@/components/icons/branch.svg";
import commitIcon from "@/components/icons/commit.svg";
import timestampIcon from "@/components/icons/timestamp.svg";
import { formatCommitSha } from "@/utils/format";
import { diffTime, formatDurationLong } from "@/utils/duration";
import { CommitSummary } from "@/services/commit";
import {
  forgeBranchUrl,
  forgeCommitUrl,
  forgeUserUrl,
} from "@/utils/forge";
import { useConfig } from "@/store/configContext";
import styles from "./styles.module.css";

type Props = {
  commit: CommitSummary;
  link?: boolean;
  className?: string;
};

const createHeaderProps = (commit: CommitSummary, giteaUrl: string) => {
  const owner = commit.repoUser;
  const repo = commit.repoName;
  return [
    {
      icon: repoIcon,
      label: "repository",
      url: `/repo/${owner}/${repo}`,
      external: false,
      value: `${owner}/${repo}`,
    },
    {
      icon: branchIcon,
      label: "branch",
      url: commit.branch
        ? forgeBranchUrl(commit.forge, giteaUrl, owner, repo, commit.branch)
        : undefined,
      external: true,
      value: commit.branch,
    },
    {
      icon: commitIcon,
      label: "commit",
      url: forgeCommitUrl(commit.forge, giteaUrl, owner, repo, commit.gitCommit),
      external: true,
      value: formatCommitSha(commit),
    },
  ];
};

export const CommitBuildsSummary = ({
  link = false,
  commit,
  className,
}: Props) => {
  const { giteaUrl } = useConfig();
  const wrapper = link
    ? (children: ReactNode) => (
        <Link href={`/commit/${commit.gitCommit}`} variant="wrapper">
          {children}
        </Link>
      )
    : (children: ReactNode) => <>{children}</>;
  return wrapper(
    <div
      className={`${styles.container} ${link ? styles.link : ""} ${className}`}
    >
      <div>
        <div className={styles.header}>
          {createHeaderProps(commit, giteaUrl).map(
            ({ icon, label, url, external, value }) => (
              <Text key={label} className={styles.status}>
                <Image key={label} src={icon} alt={label} />
                {link || !url ? (
                  value
                ) : external ? (
                  <Link href={url} target="_blank" rel="noreferrer">
                    {value}
                  </Link>
                ) : (
                  <Link href={url}>{value}</Link>
                )}
              </Text>
            ),
          )}
        </div>
        <Text className={`${styles.timestamp} ${styles.status}`}>
          <Image src={timestampIcon} alt="timestamp" />
          {formatDurationLong(diffTime(new Date(), commit.startTime))} ago by{" "}
          {link ? (
            `@${commit.reqUser}`
          ) : (
            <Link
              href={forgeUserUrl(commit.forge, giteaUrl, commit.reqUser)}
              target="_blank"
              rel="noreferrer"
            >
              @{commit.reqUser}
            </Link>
          )}
        </Text>
      </div>
      <div className={styles.statuses}>
        {(() => {
          const { succeeded, failed, pending, running, cancelled } = commit;
          return (
            <>
              {succeeded > 0 && (
                <Text className={styles.status}>
                  <StatusIcon status="Success" />
                  {getSuccessText(
                    succeeded,
                    failed,
                    pending + running,
                    cancelled,
                  )}
                </Text>
              )}
              {failed > 0 && (
                <Text className={styles.status}>
                  <StatusIcon status="Failure" />
                  {failed}
                </Text>
              )}
              {running > 0 && (
                <Text className={styles.status}>
                  <StatusIcon status="Running" />
                  {running}
                </Text>
              )}
              {pending > 0 && (
                <Text className={styles.status}>
                  <StatusIcon status="Pending" />
                  {pending}
                </Text>
              )}
              {cancelled > 0 && (
                <Text className={styles.status}>
                  <StatusIcon status="Cancelled" />
                  {cancelled}
                </Text>
              )}
            </>
          );
        })()}
      </div>
    </div>,
  );
};

const getSuccessText = (
  success: number,
  fail: number,
  pending: number,
  cancelled: number,
): string => {
  if (success <= 0) throw Error("unreachable");
  if (fail > 0 || pending > 0 || cancelled > 0) return success.toString();
  return `${success} build${success > 1 ? "s" : ""} succeeded`;
};
