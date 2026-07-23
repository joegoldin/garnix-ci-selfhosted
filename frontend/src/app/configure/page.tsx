"use client";

import React from "react";
import { AppPage } from "@/utils/appPage";
import { Text } from "@/components/text";
import { Button } from "@/components/button";
import { Link } from "@/components/link";
import { Loading } from "@/components/loading";
import { ToggleSwitch } from "@/components/toggleSwitch";
import { useConfig } from "@/store/configContext";
import { useLoading } from "@/hooks/useLoading";
import { formatBytes } from "@/utils/format";
import { RepoPicker } from "@/app/modules/configure/moduleInputs/repoPicker";
import {
  ArtifactRepoOverride,
  ConfigureSettings,
  ConnectedDomain,
  LockedArtifactBuild,
  RepoOverride,
  addConnectedDomain,
  deleteConnectedDomain,
  deleteRepoArtifactSettings,
  deleteRepoBuildTimeout,
  deleteRepoEvaluationMemory,
  getBuiltRepos,
  getConfigureSettings,
  getConnectedDomains,
  setDefaultArtifactSettings,
  setDefaultBuildTimeout,
  setRepoArtifactSettings,
  setRepoBuildTimeout,
  setRepoDefaultAuthentik,
  setRepoEvaluationMemory,
  verifyConnectedDomain,
  verifyConfiguredDomain,
} from "@/services/configure";
import {
  artifactLatestZipUrl,
  unlockBuildArtifacts,
} from "@/services/artifacts";
import styles from "./styles.module.css";

// Build/eval timeouts are stored as whole minutes; the UI works in hours.
// "" (empty) -> null = cleared (falls back to the 1h default); "0" -> 0 = no
// limit; otherwise rounded to whole minutes with a 1-minute floor.
const hoursToMinutes = (s: string): number | null => {
  if (s.trim() === "") return null;
  const h = parseFloat(s);
  if (isNaN(h) || h < 0) return null;
  if (h === 0) return 0;
  return Math.max(1, Math.round(h * 60));
};
const minutesToHours = (m: number | null): string =>
  m == null ? "" : String(+(m / 60).toFixed(2));

const Page = () => {
  const { githubAppName, giteaUrl, selfHostMode } = useConfig();
  const settings = useLoading(getConfigureSettings);
  const domains = useLoading(getConnectedDomains);
  const repos = useLoading(getBuiltRepos);
  const [repoFilter, setRepoFilter] = React.useState("");
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
            <Button href={`${giteaUrl}/-/admin/hooks`} target="_blank">
              Configure Gitea webhooks →
            </Button>
          )}
        </div>
      </div>

      {selfHostMode && (
        <div className={styles.section}>
          <Text type="h2" className={styles.h2}>
            Build runtime limits
          </Text>
          <Text className={styles.help}>
            Cap build duration and Nix evaluation memory. The time cap applies
            to evaluation and build phases, including pre-build nix commands. It
            defaults to 1 hour when empty; enter 0 for no limit. Evaluation
            memory defaults to 16 GiB and cannot be set lower.
          </Text>
          {settings.loading ? (
            <Loading />
          ) : !settings.data.ok ? (
            <Text className={styles.error}>{settings.data.error.message}</Text>
          ) : (
            <BuildRuntimeSettings
              settings={settings.data.data}
              reload={settings.reload}
            />
          )}
        </div>
      )}

      {selfHostMode && (
        <div className={styles.section}>
          <Text type="h2" className={styles.h2}>
            Artifacts
          </Text>
          <Text className={styles.help}>
            Build outputs published via a garnix.yaml artifacts section are
            retained for the configured number of days. Keep-latest always
            preserves the newest artifact per repo, branch, and name; locked
            builds are never reaped.
          </Text>
          {settings.loading ? (
            <Loading />
          ) : !settings.data.ok ? (
            <Text className={styles.error}>{settings.data.error.message}</Text>
          ) : (
            <ArtifactSettings
              settings={settings.data.data}
              reload={settings.reload}
            />
          )}
        </div>
      )}

      {selfHostMode && (
        <div className={styles.section}>
          <Text type="h2" className={styles.h2}>
            Connected domains
          </Text>
          <Text className={styles.help}>
            Servers can be hosted under these wildcard bases at{" "}
            <code className={styles.code}>&lt;name&gt;.&lt;base&gt;</code>.
            Operator bases (nix-configured) are read-only; register your own
            below, point its DNS at the garnix host, then Verify.
          </Text>
          {domains.loading ? (
            <Loading />
          ) : !domains.data.ok ? (
            <Text className={styles.error}>{domains.data.error.message}</Text>
          ) : (
            <ConnectedDomainsSettings
              domains={domains.data.data}
              reload={domains.reload}
            />
          )}
        </div>
      )}

      {selfHostMode && (
        <div className={styles.section}>
          <Text type="h2" className={styles.h2}>
            Repositories
          </Text>
          <Text className={styles.help}>
            Every repository garnix has built for — jump to a repo&apos;s
            builds.
          </Text>
          {repos.loading ? (
            <Loading />
          ) : !repos.data.ok ? (
            <Text className={styles.error}>{repos.data.error.message}</Text>
          ) : repos.data.data.length === 0 ? (
            <Text className={styles.help}>No repositories built yet.</Text>
          ) : (
            <>
              <input
                type="search"
                aria-label="Filter built repositories"
                className={styles.searchInput}
                placeholder="Filter repositories…"
                value={repoFilter}
                onChange={(event) => setRepoFilter(event.target.value)}
              />
              <div className={styles.repoList}>
                {repos.data.data
                  .filter((repo) =>
                    `${repo.owner}/${repo.repo}`
                      .toLocaleLowerCase()
                      .includes(repoFilter.trim().toLocaleLowerCase()),
                  )
                  .map((r) => (
                    <Link
                      key={`${r.owner}/${r.repo}`}
                      href={`/repo/${r.owner}/${r.repo}`}
                      className={styles.repoRow}
                    >
                      {r.owner}/{r.repo}
                    </Link>
                  ))}
              </div>
            </>
          )}
        </div>
      )}
    </div>
  );
};

export const parseMemoryGiB = (s: string): number | null => {
  if (s.trim() === "") return null;
  const gib = Number(s);
  if (!Number.isInteger(gib) || gib < 16) return null;
  return gib;
};

export const BuildRuntimeSettings = ({
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
  const [overrideMemoryGiB, setOverrideMemoryGiB] = React.useState("");
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
  const saveOverride = () => {
    const minutes = hoursToMinutes(overrideHours);
    const memoryGiB = parseMemoryGiB(overrideMemoryGiB);
    const invalidHours = overrideHours.trim() !== "" && minutes == null;
    const invalidMemory = overrideMemoryGiB.trim() !== "" && memoryGiB == null;
    if (!repo || invalidHours || invalidMemory) return;
    const existing = settings.repoOverrides.find(
      (o) => o.repoUser === repo.repoUser && o.repoName === repo.repoName,
    );
    if (existing == null && minutes == null && memoryGiB == null) return;
    return run(async () => {
      if (minutes == null) {
        if (existing?.buildTimeoutMinutes != null) {
          await deleteRepoBuildTimeout(repo.repoUser, repo.repoName);
        }
      } else {
        await setRepoBuildTimeout(repo.repoUser, repo.repoName, minutes);
      }
      if (memoryGiB == null) {
        if (existing?.maxEvalMemoryGib != null) {
          await deleteRepoEvaluationMemory(repo.repoUser, repo.repoName);
        }
      } else {
        await setRepoEvaluationMemory(repo.repoUser, repo.repoName, memoryGiB);
      }
      setRepo(null);
      setOverrideHours("");
      setOverrideMemoryGiB("");
    });
  };
  const editOverride = (o: RepoOverride) => {
    setRepo({ repoUser: o.repoUser, repoName: o.repoName });
    setOverrideHours(minutesToHours(o.buildTimeoutMinutes));
    setOverrideMemoryGiB(
      o.maxEvalMemoryGib == null ? "" : String(o.maxEvalMemoryGib),
    );
  };
  const removeOverride = (o: RepoOverride) =>
    run(async () => {
      if (o.buildTimeoutMinutes != null) {
        await deleteRepoBuildTimeout(o.repoUser, o.repoName);
      }
      if (o.maxEvalMemoryGib != null) {
        await deleteRepoEvaluationMemory(o.repoUser, o.repoName);
      }
    });
  // Default-OIDC hosting is approved/revoked immediately (its own endpoint),
  // independent of the timeout/memory "Save override" button.
  const toggleAuthentik = (
    repoUser: string,
    repoName: string,
    approved: boolean,
  ) => run(() => setRepoDefaultAuthentik(repoUser, repoName, approved));
  const authentikApprovedFor = (repoUser: string, repoName: string): boolean =>
    settings.repoOverrides.find(
      (o) => o.repoUser === repoUser && o.repoName === repoName,
    )?.defaultAuthentikApproved ?? false;

  return (
    <div className={styles.timeout}>
      <div className={styles.settingsPanel}>
        <div className={styles.settingsGrid}>
          <label className={styles.settingField}>
            <span>Default max build time</span>
            <span className={styles.inputWithUnit}>
              <input
                className={styles.hoursInput}
                type="number"
                min="0"
                step="0.5"
                placeholder="1"
                value={defaultHours}
                onChange={(e) => setDefaultHours(e.target.value)}
              />
              <span>hours</span>
            </span>
          </label>
          <div className={styles.settingsActions}>
            <Button onClick={saveDefault} loading={busy}>
              Save default
            </Button>
            <Button style="secondary" onClick={clearDefault} loading={busy}>
              Clear
            </Button>
          </div>
        </div>
      </div>

      <Text type="h3" className={styles.h3}>
        Per-repo overrides
      </Text>
      <Text className={styles.help}>
        Default evaluation memory: {settings.defaultMaxEvalMemoryGib} GiB
      </Text>
      <div className={styles.overrideComposer}>
        <div>
          <div className={styles.fieldLabel}>Repository</div>
          <RepoPicker value={repo} onChange={setRepo} />
        </div>
        {repo != null ? (
          <div className={styles.overrideEditor}>
            <label className={styles.settingField}>
              <span>Max build time (hours)</span>
              <input
                className={styles.hoursInput}
                type="number"
                min="0"
                step="0.5"
                placeholder="inherit default"
                value={overrideHours}
                onChange={(e) => setOverrideHours(e.target.value)}
              />
            </label>
            <label className={styles.settingField}>
              <span>Max evaluation memory (GiB)</span>
              <input
                className={styles.hoursInput}
                type="number"
                min="16"
                step="1"
                placeholder={String(settings.defaultMaxEvalMemoryGib)}
                value={overrideMemoryGiB}
                onChange={(e) => setOverrideMemoryGiB(e.target.value)}
              />
            </label>
            <div className={styles.settingsActions}>
              <Button onClick={saveOverride} loading={busy}>
                Save override
              </Button>
            </div>
            <label className={styles.toggleField}>
              <span>Allow default-OIDC hosting</span>
              <ToggleSwitch
                value={authentikApprovedFor(repo.repoUser, repo.repoName)}
                onChange={(v) => {
                  void toggleAuthentik(repo.repoUser, repo.repoName, v);
                }}
              />
            </label>
            <Text className={styles.help}>
              Lets this repo&apos;s deployed servers use{" "}
              <code className={styles.code}>authentik: default</code>, which
              hands them garnix&apos;s own login/OIDC client credentials. Only
              enable for repositories you fully trust.
            </Text>
          </div>
        ) : null}
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
              <span className={styles.overrideDetails}>
                <span className={styles.overrideValue}>
                  {o.buildTimeoutMinutes == null
                    ? "default time"
                    : `${minutesToHours(o.buildTimeoutMinutes)}h`}
                </span>
                <span className={styles.overrideValue}>
                  {o.maxEvalMemoryGib == null
                    ? `default (${settings.defaultMaxEvalMemoryGib} GiB)`
                    : `${o.maxEvalMemoryGib} GiB`}
                </span>
                <span className={styles.overrideValue}>
                  default-OIDC:{" "}
                  {o.defaultAuthentikApproved ? "allowed" : "off"}
                </span>
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

export const ConnectedDomainsSettings = ({
  domains,
  reload,
}: {
  domains: Array<ConnectedDomain>;
  reload: () => void;
}) => {
  const [newDomain, setNewDomain] = React.useState("");
  const [busy, setBusy] = React.useState(false);
  const run = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    await fn();
    setBusy(false);
    reload();
  };

  const add = () => {
    const domain = newDomain.trim();
    if (domain === "") return;
    return run(async () => {
      await addConnectedDomain(domain);
      setNewDomain("");
    });
  };
  const verify = (d: ConnectedDomain) => {
    if (d.nix_configured) return run(() => verifyConfiguredDomain(d.domain));
    const id = d.id;
    if (id == null) return;
    return run(() => verifyConnectedDomain(id));
  };
  const remove = (d: ConnectedDomain) => {
    const id = d.id;
    if (id == null || d.nix_configured) return;
    return run(() => deleteConnectedDomain(id));
  };

  return (
    <div className={styles.timeout}>
      <div className={styles.addRow}>
        <input
          className={styles.domainInput}
          type="text"
          placeholder="example.com"
          value={newDomain}
          onChange={(e) => setNewDomain(e.target.value)}
        />
        <Button onClick={add} loading={busy}>
          Add
        </Button>
      </div>

      {domains.length === 0 ? (
        <Text className={styles.help}>No connected domains yet.</Text>
      ) : (
        <ul className={styles.overrideList}>
          {domains.map((d) => (
            <li
              key={`${d.nix_configured ? "configured" : "connected"}-${d.domain}`}
              className={styles.overrideRow}
            >
              <span className={styles.overrideRepo}>{d.domain}</span>
              {d.nix_configured && (
                <span className={`${styles.badge} ${styles.badgeBase}`}>
                  wildcard base
                </span>
              )}
              <span
                className={`${styles.badge} ${
                  d.verified ? styles.badgeVerified : styles.badgeUnverified
                }`}
              >
                {d.verified ? "resolves here" : "not verified"}
              </span>
              <span className={styles.overrideActions}>
                {d.nix_configured && (
                  <span className={styles.readonlyNote}>nix-configured</span>
                )}
                {!d.verified && (
                  <Button
                    style="secondary"
                    onClick={() => verify(d)}
                    loading={busy}
                  >
                    Verify
                  </Button>
                )}
                {!d.nix_configured && d.id != null && (
                  <Button
                    style="warning"
                    onClick={() => remove(d)}
                    loading={busy}
                  >
                    Delete
                  </Button>
                )}
              </span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
};

// Retention is stored as whole days; empty/invalid -> null (inherit/invalid).
const parseDays = (s: string): number | null => {
  const n = parseInt(s, 10);
  return isNaN(n) || n < 1 ? null : n;
};

type KeepLatestChoice = "inherit" | "on" | "off";

// Latest-URLs exist per (repo, branch, name); locked builds are the only
// configure datum that carries branch+name, so derive the list from those.
const distinctLatestUrls = (
  builds: Array<LockedArtifactBuild>,
): Array<{ key: string; label: string; url: string }> => {
  const out = new Map<string, { label: string; url: string }>();
  for (const b of builds) {
    const url = artifactLatestZipUrl({
      repo_user: b.repoUser,
      repo_name: b.repoName,
      branch: b.branch,
      name: b.name,
    });
    if (url == null) continue;
    const key = `${b.repoUser}/${b.repoName}/${b.branch}/${b.name}`;
    if (!out.has(key))
      out.set(key, {
        label: `${b.repoUser}/${b.repoName} @ ${b.branch} · ${b.name}`,
        url,
      });
  }
  return Array.from(out.entries()).map(([key, v]) => ({ key, ...v }));
};

const ArtifactSettings = ({
  settings,
  reload,
}: {
  settings: ConfigureSettings;
  reload: () => void;
}) => {
  const [retentionDays, setRetentionDays] = React.useState(
    String(settings.artifactRetentionDays),
  );
  const [keepLatest, setKeepLatest] = React.useState(
    settings.artifactKeepLatest,
  );
  const [repo, setRepo] = React.useState<{
    repoUser: string;
    repoName: string;
  } | null>(null);
  const [overrideDays, setOverrideDays] = React.useState("");
  const [overrideKeepLatest, setOverrideKeepLatest] =
    React.useState<KeepLatestChoice>("inherit");
  const [busy, setBusy] = React.useState(false);

  const run = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    await fn();
    setBusy(false);
    reload();
  };

  const saveDefault = () => {
    const days = parseDays(retentionDays);
    if (days == null) return;
    return run(() => setDefaultArtifactSettings(days, keepLatest));
  };
  const addOverride = () => {
    if (repo == null) return;
    const days = overrideDays.trim() === "" ? null : parseDays(overrideDays);
    const keep =
      overrideKeepLatest === "inherit" ? null : overrideKeepLatest === "on";
    // An override with both fields inheriting is a no-op; don't create it.
    if (days == null && keep == null) return;
    return run(async () => {
      await setRepoArtifactSettings(repo.repoUser, repo.repoName, days, keep);
      setRepo(null);
      setOverrideDays("");
      setOverrideKeepLatest("inherit");
    });
  };
  const editOverride = (o: ArtifactRepoOverride) => {
    setRepo({ repoUser: o.repoUser, repoName: o.repoName });
    setOverrideDays(o.retentionDays == null ? "" : String(o.retentionDays));
    setOverrideKeepLatest(
      o.keepLatest == null ? "inherit" : o.keepLatest ? "on" : "off",
    );
  };
  const removeOverride = (o: ArtifactRepoOverride) =>
    run(() => deleteRepoArtifactSettings(o.repoUser, o.repoName));
  const unlock = (b: LockedArtifactBuild) =>
    run(() => unlockBuildArtifacts(b.buildId));

  const totalUsage = settings.artifactUsage.reduce(
    (acc, u) => acc + u.totalSize,
    0,
  );
  const latestUrls = distinctLatestUrls(settings.lockedArtifactBuilds);

  return (
    <div className={styles.timeout}>
      <div className={styles.settingsPanel}>
        <div className={styles.settingsGrid}>
          <label className={styles.settingField}>
            <span>Retention (days)</span>
            <input
              className={styles.hoursInput}
              type="number"
              min="1"
              step="1"
              placeholder="30"
              value={retentionDays}
              onChange={(e) => setRetentionDays(e.target.value)}
            />
          </label>
          <label className={styles.toggleField}>
            <span>Keep latest per branch</span>
            <ToggleSwitch value={keepLatest} onChange={setKeepLatest} />
          </label>
          <div className={styles.settingsActions}>
            <Button onClick={saveDefault} loading={busy}>
              Save default
            </Button>
          </div>
        </div>
      </div>

      <Text type="h3" className={styles.h3}>
        Per-repo overrides
      </Text>
      <div className={styles.overrideComposer}>
        <div>
          <div className={styles.fieldLabel}>Repository</div>
          <RepoPicker value={repo} onChange={setRepo} />
        </div>
        {repo != null ? (
          <div className={styles.overrideEditor}>
            <label className={styles.settingField}>
              <span>Retention (days)</span>
              <input
                className={styles.hoursInput}
                type="number"
                min="1"
                step="1"
                placeholder="inherit default"
                value={overrideDays}
                onChange={(e) => setOverrideDays(e.target.value)}
              />
            </label>
            <label className={styles.settingField}>
              <span>Keep latest per branch</span>
              <select
                className={styles.keepLatestSelect}
                value={overrideKeepLatest}
                onChange={(e) =>
                  setOverrideKeepLatest(e.target.value as KeepLatestChoice)
                }
              >
                <option value="inherit">Inherit default</option>
                <option value="on">On</option>
                <option value="off">Off</option>
              </select>
            </label>
            <div className={styles.settingsActions}>
              <Button onClick={addOverride} loading={busy}>
                Save override
              </Button>
            </div>
          </div>
        ) : null}
      </div>

      {settings.artifactRepoOverrides.length === 0 ? (
        <Text className={styles.help}>No per-repo overrides yet.</Text>
      ) : (
        <ul className={styles.overrideList}>
          {settings.artifactRepoOverrides.map((o) => (
            <li
              key={`${o.repoUser}/${o.repoName}`}
              className={styles.overrideRow}
            >
              <span className={styles.overrideRepo}>
                {o.repoUser}/{o.repoName}
              </span>
              <span className={styles.overrideValue}>
                {o.retentionDays == null ? "inherit" : `${o.retentionDays}d`} ·
                keep latest:{" "}
                {o.keepLatest == null ? "inherit" : o.keepLatest ? "on" : "off"}
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
                  Clear
                </Button>
              </span>
            </li>
          ))}
        </ul>
      )}

      <Text type="h3" className={styles.h3}>
        Storage usage
      </Text>
      {settings.artifactUsage.length === 0 ? (
        <Text className={styles.help}>No artifacts stored yet.</Text>
      ) : (
        <ul className={styles.overrideList}>
          {settings.artifactUsage.map((u) => (
            <li
              key={`${u.repoUser}/${u.repoName}`}
              className={styles.overrideRow}
            >
              <span className={styles.overrideRepo}>
                {u.repoUser}/{u.repoName}
              </span>
              <span className={styles.overrideValue}>
                {formatBytes(u.totalSize)}
              </span>
            </li>
          ))}
          <li className={`${styles.overrideRow} ${styles.usageTotal}`}>
            <span className={styles.overrideRepo}>Total</span>
            <span className={styles.overrideValue}>
              {formatBytes(totalUsage)}
            </span>
          </li>
        </ul>
      )}

      <Text type="h3" className={styles.h3}>
        Locked builds
      </Text>
      {settings.lockedArtifactBuilds.length === 0 ? (
        <Text className={styles.help}>No locked artifact builds.</Text>
      ) : (
        <ul className={styles.overrideList}>
          {settings.lockedArtifactBuilds.map((b) => (
            <li key={`${b.buildId}-${b.name}`} className={styles.overrideRow}>
              <span className={styles.overrideRepo}>
                {b.repoUser}/{b.repoName}
                {b.branch != null ? ` @ ${b.branch}` : ""}
              </span>
              <Link href={`/build/${b.buildId}`}>{b.name}</Link>
              <span className={styles.overrideValue}>
                {b.createdAt.toLocaleDateString(undefined, {
                  dateStyle: "medium",
                })}
              </span>
              <span className={styles.overrideActions}>
                <Button
                  style="warning"
                  onClick={() => unlock(b)}
                  loading={busy}
                >
                  Unlock
                </Button>
              </span>
            </li>
          ))}
        </ul>
      )}

      {latestUrls.length > 0 ? (
        <>
          <Text type="h3" className={styles.h3}>
            Latest artifact URLs
          </Text>
          <div className={styles.latestUrls}>
            {latestUrls.map((u) => (
              <CopyableUrl key={u.key} label={u.label} url={u.url} />
            ))}
          </div>
        </>
      ) : null}
    </div>
  );
};

// A copyable stable-URL row; same copy pattern as the servers page's
// CopyableCommand. Displays the path, copies the absolute URL.
const CopyableUrl = ({ label, url }: { label: string; url: string }) => {
  const [copied, setCopied] = React.useState(false);
  return (
    <div className={styles.cmdRow}>
      <span className={styles.cmdLabel}>{label}</span>
      <code className={styles.cmd}>{url}</code>
      <button
        type="button"
        className={styles.copyBtn}
        title="Copy to clipboard"
        onClick={() => {
          void navigator.clipboard?.writeText(
            `${window.location.origin}${url}`,
          );
          setCopied(true);
          window.setTimeout(() => setCopied(false), 1200);
        }}
      >
        {copied ? "Copied" : "Copy"}
      </button>
    </div>
  );
};

export default AppPage(Page, { requireAuth: true });
