import { GithubIcon } from "@/components/icons/github";
import { InputProps } from "@/components/input";
import { useLoading } from "@/hooks/useLoading";
import { getRepos } from "@/services/account";
import { Button } from "@/components/button";
import { Loading } from "@/components/loading";
import styles from "./styles.module.css";

export const RepoPicker = (
  props: InputProps<{ repoUser: string; repoName: string } | null>,
) => {
  return props.value == null ? (
    <RepoUnchosen onChange={props.onChange} />
  ) : (
    <RepoChosen value={props.value} onChange={props.onChange} />
  );
};

const RepoChosen = (props: {
  value: { repoUser: string; repoName: string };
  onChange: (v: null) => void;
}) => (
  <div className={styles.chosen}>
    <div className={styles.repo}>
      <GithubIcon className={styles.ghIcon} />
      <span>
        {props.value.repoUser} / {props.value.repoName}
      </span>
    </div>
    <Button onClick={() => props.onChange(null)}>Change Repository</Button>
  </div>
);

const RepoUnchosen = (props: {
  onChange: (v: { repoUser: string; repoName: string }) => void;
}) => {
  const repos = useLoading(getRepos);
  if (repos.loading)
    return (
      <div className={styles.loading}>
        <Loading />
        <span>Fetching your repositories...</span>
      </div>
    );
  if (!repos.data.ok)
    return (
      <div>
        Sorry, something went wrong fetching your repos.{" "}
        <Button onClick={repos.reload}>Try again</Button>
      </div>
    );

  return (
    <div className={styles.repoList}>
      {repos.data.data.map((repo) => (
        <div
          className={styles.repoRow}
          key={`${repo.repoUser}/${repo.repoName}`}
        >
          <GithubIcon className={styles.ghIcon} />
          <span>
            {repo.repoUser} / {repo.repoName}
          </span>
          <Button onClick={() => props.onChange(repo)}>Select</Button>
        </div>
      ))}
    </div>
  );
};
