import { Repo } from "./modules";

export const getRepoKey = async (repo: Repo) => {
  const response = await fetch(
    `/api/keys/${repo.repoUser}/${repo.repoName}/repo-key.public`,
  );
  return await response.text();
};
