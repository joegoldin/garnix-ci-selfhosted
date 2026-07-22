import React from "react";
import { Text } from "@/components/text";
import { Modal, ModalActions, ModalSection } from "@/components/modal";
import { CommitBuildsSummary } from "@/components/build";
import { Button } from "@/components/button";
import { Select } from "@/components/select";
import { GithubIcon } from "@/components/icons/github";
import { useConfig } from "@/store/configContext";
import { useLoading } from "@/hooks/useLoading";
import { CommitSummary, getCommits, getCommitsForRepo } from "@/services/commit";
import { getArtifactCommitCounts } from "@/services/artifacts";
import { fromSecs } from "@/utils/duration";
import { Link } from "@/components/link";
import styles from "./styles.module.css";

type CommitListFor = "reqUser" | { owner: string; repo: string };

type CommitStatus = "Running" | "Failed" | "Succeeded" | "Cancelled";

// A commit's overall state, most-in-progress first.
const commitStatus = (c: CommitSummary): CommitStatus => {
  if (c.pending + c.running > 0) return "Running";
  if (c.failed > 0) return "Failed";
  if (c.cancelled > 0) return "Cancelled";
  return "Succeeded";
};

export const CommitList = (props: {
  for: CommitListFor;
  headerRight?: React.ReactNode;
}) => {
  const { githubAppName } = useConfig();
  const setupUrl = `https://github.com/apps/${githubAppName}/installations/new`;

  const getCommitsFn = React.useCallback(
    () =>
      props.for === "reqUser"
        ? getCommits()
        : getCommitsForRepo(props.for.owner, props.for.repo),
    [props.for],
  );

  const [statusFilter, setStatusFilter] = React.useState<CommitStatus | null>(
    null,
  );

  const loadingCommits = useLoading(getCommitsFn, { poll: fromSecs(5) });

  // Distinct repos among the loaded commits (for a repo page it's just that
  // repo; for the reqUser dashboard, every repo the commits span). Empty until
  // commits load. `reposKey` stabilizes it so the counts fetch below only
  // re-runs when the SET of repos changes, not on every poll.
  const repos: Array<{ owner: string; repo: string }> = React.useMemo(() => {
    if (props.for !== "reqUser") return [props.for];
    if (loadingCommits.loading || !loadingCommits.data.ok) return [];
    const seen = new Set<string>();
    const out: Array<{ owner: string; repo: string }> = [];
    for (const c of loadingCommits.data.data) {
      const key = `${c.repoUser}/${c.repoName}`;
      if (!seen.has(key)) {
        seen.add(key);
        out.push({ owner: c.repoUser, repo: c.repoName });
      }
    }
    return out;
  }, [props.for, loadingCommits]);
  const reposKey = repos.map((r) => `${r.owner}/${r.repo}`).join(",");

  // Per-(repo, commit) published-artifact counts for the row badges. The counts
  // endpoint is per-repo, so fetch it for each distinct repo shown and key by
  // `owner/repo/commit` (works for both a single repo page and the cross-repo
  // dashboard). Tolerates a 404 (no artifact store configured) -> no badges.
  const loadArtifactCounts = React.useCallback(
    () =>
      Promise.all(
        repos.map((r) =>
          getArtifactCommitCounts(r.owner, r.repo).then((result) =>
            result.ok
              ? result.data.map(
                  (c) => [`${r.owner}/${r.repo}/${c.commit}`, c.count] as const,
                )
              : [],
          ),
        ),
      ).then((entries) => Object.fromEntries(entries.flat())),
    // `reposKey` stabilizes `repos`; refetch only when the repo set changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [reposKey],
  );
  const artifactCounts = useLoading(loadArtifactCounts);
  if (loadingCommits.loading) return null;
  if (!loadingCommits.data.ok) {
    return (
      <div className={styles.error}>{loadingCommits.data.error.message}</div>
    );
  }
  const commits = loadingCommits.data.data;
  const shown = statusFilter
    ? commits.filter((c) => commitStatus(c) === statusFilter)
    : commits;
  const artifactCountByKey = artifactCounts.loading
    ? {}
    : artifactCounts.data;
  return commits.length > 0 ? (
    <div className={styles.container}>
      <div className={styles.header}>
        <div className={styles.headerLeft}>
          <Text type="h1" className={styles.h1}>
            Builds
          </Text>
          <Select
            value={statusFilter}
            onChange={setStatusFilter}
            options={[
              [null, "All Builds"],
              ["Running", "Running"],
              ["Failed", "Failed"],
              ["Succeeded", "Succeeded"],
              ["Cancelled", "Cancelled"],
            ]}
          />
        </div>
        {props.headerRight}
      </div>
      <ol>
        {shown.map((commit) => (
          <CommitBuildsSummary
            className={styles.build}
            key={commit.gitCommit}
            commit={commit}
            artifactCount={
              artifactCountByKey[
                `${commit.repoUser}/${commit.repoName}/${commit.gitCommit}`
              ]
            }
            link
          />
        ))}
      </ol>
    </div>
  ) : (
    <div className={styles.containerZeroState}>
      <Modal>
        <ModalSection>
          <Text type="h1" className={styles.h1}>
            Your builds will appear here once some have been created.
          </Text>
          <Text type="p" className={styles.p}>
            To build, just push a commit to any enabled repository that contains
            a flake.nix. If you need help creating a flake.nix for your repo,
            check out our{" "}
            <Link href="/modules/configure" className={styles.link}>
              modules page
            </Link>
            .
          </Text>
        </ModalSection>
        <ModalSection>
          <Text className={styles.p}>Need help getting started?</Text>
          <ModalActions>
            <Button href={setupUrl} eventName="install-the-app" target="">
              <GithubIcon />
              Setup Garnix on a simple repo
            </Button>
          </ModalActions>
        </ModalSection>
      </Modal>
    </div>
  );
};
