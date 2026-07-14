"use client";

import React from "react";
import { WithSidebar } from "@/components/withSidebar";
import { CommitList } from "@/components/commitList";
import { Button } from "@/components/button";
import { useConfig } from "@/store/configContext";
import { useLoading } from "@/hooks/useLoading";
import { getCommitsForRepo } from "@/services/commit";
import { forgeRepoUrl } from "@/utils/forge";

const Page = ({ params }: { params: { owner: string; repo: string } }) => {
  const { giteaUrl } = useConfig();
  const loadCommits = React.useCallback(
    () => getCommitsForRepo(params.owner, params.repo),
    [params.owner, params.repo],
  );
  const loadingCommits = useLoading(loadCommits);
  // A repo's builds all share one forge; default to GitHub when we have no
  // commits to read it from.
  const forge =
    !loadingCommits.loading && loadingCommits.data.ok
      ? (loadingCommits.data.data[0]?.forge ?? "github")
      : "github";
  const isGitea = forge === "gitea" && giteaUrl.length > 0;
  return (
    <WithSidebar>
      <CommitList
        for={params}
        headerRight={
          <Button
            href={forgeRepoUrl(forge, giteaUrl, params.owner, params.repo)}
            target="_blank"
          >
            View on {isGitea ? "Gitea" : "GitHub"} →
          </Button>
        }
      />
    </WithSidebar>
  );
};

export default Page;
