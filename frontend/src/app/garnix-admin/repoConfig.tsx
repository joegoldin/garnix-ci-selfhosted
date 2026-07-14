"use client";

import { useState } from "react";
import { Button } from "@/components/button";
import { getRepoConfig, setRepoConfig, RepoConfig } from "@/services/admin";

// Admin-only editor for per-repo config. Lets an operator allow a public repo
// to depend on private flake inputs, and route that repo's build outputs to the
// private (authenticated) cache bucket so nothing leaks to the public cache.
const RepoConfigEditor = () => {
  const [owner, setOwner] = useState("");
  const [repo, setRepo] = useState("");
  const [config, setConfig] = useState<RepoConfig | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = async () => {
    setStatus(null);
    setBusy(true);
    const res = await getRepoConfig(owner.trim(), repo.trim());
    setBusy(false);
    if (!res.ok) {
      setConfig(null);
      setStatus(`Error loading: ${res.error.message}`);
      return;
    }
    setConfig(res.data);
    setStatus(`Loaded config for ${owner.trim()}/${repo.trim()}.`);
  };

  const save = async () => {
    if (config == null) return;
    setStatus(null);
    setBusy(true);
    const res = await setRepoConfig(owner.trim(), repo.trim(), config);
    setBusy(false);
    setStatus(
      res.ok
        ? `Saved config for ${owner.trim()}/${repo.trim()}.`
        : `Error saving: ${res.error.message}`,
    );
  };

  return (
    <div>
      <h2>Per-repo config</h2>
      <p>
        Allow a public repo to use private flake inputs. Pair it with
        &ldquo;private cache&rdquo; so the resulting closures are only served to
        authenticated clients.
      </p>
      <div style={{ display: "flex", gap: "0.5rem", alignItems: "center" }}>
        <input
          placeholder="owner"
          value={owner}
          onChange={(e) => setOwner(e.target.value)}
        />
        <span>/</span>
        <input
          placeholder="repo"
          value={repo}
          onChange={(e) => setRepo(e.target.value)}
        />
        <Button
          onClick={load}
          loading={busy}
          style="secondary"
        >
          Load
        </Button>
      </div>
      {config != null && (
        <div style={{ marginTop: "1rem" }}>
          <label style={{ display: "block", marginBottom: "0.5rem" }}>
            <input
              type="checkbox"
              checked={config.skipPrivateInputsCheck}
              onChange={(e) =>
                setConfig({
                  ...config,
                  skipPrivateInputsCheck: e.target.checked,
                })
              }
            />{" "}
            Allow private flake inputs (skip the public-repo private-deps check)
          </label>
          <label style={{ display: "block", marginBottom: "0.5rem" }}>
            <input
              type="checkbox"
              checked={config.privateCache}
              onChange={(e) =>
                setConfig({ ...config, privateCache: e.target.checked })
              }
            />{" "}
            Route cache to the private (authenticated) bucket
          </label>
          <Button onClick={save} loading={busy}>
            Save
          </Button>
        </div>
      )}
      {status && (
        <p style={{ marginTop: "1rem" }}>
          <em>{status}</em>
        </p>
      )}
    </div>
  );
};

export default RepoConfigEditor;
