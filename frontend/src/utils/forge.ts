// Forge-aware external URL builders. GitHub is the default forge everywhere;
// when a build/commit carries `forge === "gitea"` and a Gitea instance is
// configured (non-empty `giteaUrl`, no trailing slash), links point at the
// self-hosted Gitea instead.

const GITHUB_BASE = "https://github.com";

const isGitea = (forge: string, giteaUrl: string): boolean =>
  forge === "gitea" && giteaUrl.length > 0;

export const forgeRepoUrl = (
  forge: string,
  giteaUrl: string,
  owner: string,
  repo: string,
): string =>
  isGitea(forge, giteaUrl)
    ? `${giteaUrl}/${owner}/${repo}`
    : `${GITHUB_BASE}/${owner}/${repo}`;

export const forgeBranchUrl = (
  forge: string,
  giteaUrl: string,
  owner: string,
  repo: string,
  branch: string,
): string =>
  isGitea(forge, giteaUrl)
    ? `${giteaUrl}/${owner}/${repo}/src/branch/${branch}`
    : `${GITHUB_BASE}/${owner}/${repo}/tree/${branch}`;

export const forgeCommitUrl = (
  forge: string,
  giteaUrl: string,
  owner: string,
  repo: string,
  sha: string,
): string =>
  isGitea(forge, giteaUrl)
    ? `${giteaUrl}/${owner}/${repo}/commit/${sha}`
    : `${GITHUB_BASE}/${owner}/${repo}/commit/${sha}`;

export const forgeUserUrl = (
  forge: string,
  giteaUrl: string,
  login: string,
): string =>
  isGitea(forge, giteaUrl) ? `${giteaUrl}/${login}` : `${GITHUB_BASE}/${login}`;
