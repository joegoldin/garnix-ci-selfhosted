import React from "react";
import { Select } from "@/components/select";
import { RunningServer } from "@/services/servers";
import styles from "./styles.module.css";

export type Filters = {
  repo: null | string;
  type: null | RunningServer["type"]["tag"];
  status: null | RunningServer["status"];
};

export const useFilters = () => {
  const [filters, setFilters] = React.useState<Filters>({
    repo: null,
    type: null,
    status: "Online",
  });
  const shouldDisplay = (s: RunningServer) =>
    (filters.repo ? filters.repo === `${s.repo_owner}/${s.repo_name}` : true) &&
    (filters.type ? filters.type === s.type.tag : true) &&
    (filters.status ? filters.status === s.status : true);
  return { filters, setFilters, shouldDisplay };
};

export const ServerFilters = (
  props: { servers: Array<RunningServer> } & ReturnType<typeof useFilters>,
) => {
  const uniqueServers = React.useMemo(
    () =>
      Array.from(
        new Set(props.servers.map((s) => `${s.repo_owner}/${s.repo_name}`)),
      ),
    [props.servers],
  );
  const getOnChange =
    <K extends keyof Filters>(filterKey: K) =>
    (value: Filters[K]) =>
      props.setFilters({ ...props.filters, [filterKey]: value });
  return (
    <div className={styles.container}>
      <Select
        value={props.filters.repo || null}
        onChange={getOnChange("repo")}
        options={[
          [null, "All Repos"],
          ...uniqueServers.map((repo) => [repo, `Repo: ${repo}`] as const),
        ]}
      />
      <Select
        value={props.filters.type || null}
        onChange={getOnChange("type")}
        options={[
          [null, "All Deploy Types"],
          ["BranchDeployment", "Branch Deployments"],
          ["GhPrDeployment", "PR Deployments"],
        ]}
      />
      <Select
        value={props.filters.status || null}
        onChange={getOnChange("status")}
        options={[
          [null, "All Statuses"],
          ["Online", "Online"],
          ["Failed", "Failed"],
          ["Booting", "Booting"],
          ["Ended", "Ended"],
        ]}
      />
    </div>
  );
};
