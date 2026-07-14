"use client";

import React from "react";
import { AppPage } from "@/utils/appPage";
import { Text } from "@/components/text";
import { Button } from "@/components/button";
import { Loading } from "@/components/loading";
import { useConfig } from "@/store/configContext";
import { useLoading } from "@/hooks/useLoading";
import { RepoPicker } from "@/app/modules/configure/moduleInputs/repoPicker";
import {
  ConfigureSettings,
  RepoOverride,
  getConfigureSettings,
  setDefaultBuildTimeout,
  setRepoBuildTimeout,
  deleteRepoBuildTimeout,
} from "@/services/configure";
import styles from "./styles.module.css";

// Build/eval timeouts are stored as whole minutes; the UI works in hours.
const hoursToMinutes = (s: string): number | null => {
  const h = parseFloat(s);
  if (isNaN(h) || h <= 0) return null;
  return Math.max(1, Math.round(h * 60));
};
const minutesToHours = (m: number | null): string =>
  m == null ? "" : String(+(m / 60).toFixed(2));

const Page = () => {
  const { githubAppName, giteaUrl, selfHostMode } = useConfig();
  const settings = useLoading(getConfigureSettings);
  return (
    <div className={styles.container}>
      <Text type="h1" className={styles.h1}>
        Configure
      </Text>

      <div className={styles.section}>
        <Text type="h2" className={styles.h2}>
          Forge configuration
        </Text>
        <Text className={styles.help}>
          Manage which repositories build here from each forge&apos;s webhook
          settings.
        </Text>
        <div className={styles.buttonRow}>
          <Button
            href={`https://github.com/apps/${githubAppName}`}
            target="_blank"
          >
            Configure GitHub App →
          </Button>
          {giteaUrl.length > 0 && (
            <Button
              href={`${giteaUrl}/-/admin/hooks`}
              target="_blank"
              style="secondary"
            >
              Configure Gitea webhooks →
            </Button>
          )}
        </div>
      </div>

      {selfHostMode && (
        <div className={styles.section}>
          <Text type="h2" className={styles.h2}>
            Build timeout
          </Text>
          <Text className={styles.help}>
            Cap how long a build may run before it is stopped. The cap applies
            to both the evaluation and build phases. Leave the default empty for
            no limit.
          </Text>
          {settings.loading ? (
            <Loading />
          ) : !settings.data.ok ? (
            <Text className={styles.error}>{settings.data.error.message}</Text>
          ) : (
            <BuildTimeoutSettings
              settings={settings.data.data}
              reload={settings.reload}
            />
          )}
        </div>
      )}
    </div>
  );
};

const BuildTimeoutSettings = ({
  settings,
  reload,
}: {
  settings: ConfigureSettings;
  reload: () => void;
}) => {
  const [defaultHours, setDefaultHours] = React.useState(
    minutesToHours(settings.defaultBuildTimeoutMinutes),
  );
  const [repo, setRepo] = React.useState<{
    repoUser: string;
    repoName: string;
  } | null>(null);
  const [overrideHours, setOverrideHours] = React.useState("");
  const [busy, setBusy] = React.useState(false);

  const run = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    await fn();
    setBusy(false);
    reload();
  };

  const saveDefault = () =>
    run(() => setDefaultBuildTimeout(hoursToMinutes(defaultHours)));
  const clearDefault = () =>
    run(async () => {
      await setDefaultBuildTimeout(null);
      setDefaultHours("");
    });
  const addOverride = () => {
    const minutes = hoursToMinutes(overrideHours);
    if (!repo || minutes == null) return;
    return run(async () => {
      await setRepoBuildTimeout(repo.repoUser, repo.repoName, minutes);
      setRepo(null);
      setOverrideHours("");
    });
  };
  const editOverride = (o: RepoOverride) => {
    setRepo({ repoUser: o.repoUser, repoName: o.repoName });
    setOverrideHours(minutesToHours(o.buildTimeoutMinutes));
  };
  const removeOverride = (o: RepoOverride) =>
    run(() => deleteRepoBuildTimeout(o.repoUser, o.repoName));

  return (
    <div className={styles.timeout}>
      <div className={styles.defaultRow}>
        <label className={styles.label}>Default max build time (hours)</label>
        <input
          className={styles.hoursInput}
          type="number"
          min="0"
          step="0.5"
          placeholder="none"
          value={defaultHours}
          onChange={(e) => setDefaultHours(e.target.value)}
        />
        <Button onClick={saveDefault} loading={busy}>
          Save default
        </Button>
        <Button style="secondary" onClick={clearDefault} loading={busy}>
          Clear
        </Button>
      </div>

      <Text type="h3" className={styles.h3}>
        Per-repo overrides
      </Text>
      <div className={styles.addRow}>
        <div className={styles.picker}>
          <RepoPicker value={repo} onChange={setRepo} />
        </div>
        <input
          className={styles.hoursInput}
          type="number"
          min="0"
          step="0.5"
          placeholder="hours"
          value={overrideHours}
          onChange={(e) => setOverrideHours(e.target.value)}
        />
        <Button onClick={addOverride} loading={busy}>
          Add override
        </Button>
      </div>

      {settings.repoOverrides.length === 0 ? (
        <Text className={styles.help}>No per-repo overrides yet.</Text>
      ) : (
        <ul className={styles.overrideList}>
          {settings.repoOverrides.map((o) => (
            <li
              key={`${o.repoUser}/${o.repoName}`}
              className={styles.overrideRow}
            >
              <span className={styles.overrideRepo}>
                {o.repoUser}/{o.repoName}
              </span>
              <span className={styles.overrideValue}>
                {minutesToHours(o.buildTimeoutMinutes)}h
              </span>
              <span className={styles.overrideActions}>
                <Button style="secondary" onClick={() => editOverride(o)}>
                  Edit
                </Button>
                <Button
                  style="warning"
                  onClick={() => removeOverride(o)}
                  loading={busy}
                >
                  Delete
                </Button>
              </span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
};

export default AppPage(Page, { requireAuth: true });
