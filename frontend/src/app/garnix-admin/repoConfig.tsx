"use client";

import { useState } from "react";
import { Button } from "@/components/button";
import { Loading } from "@/components/loading";
import { useLoading } from "@/hooks/useLoading";
import {
  PrivateInputForkRequest,
  getPrivateInputForkRequests,
  setPrivateInputForkApproval,
} from "@/services/admin";
import styles from "./repoConfig.module.css";

// Trusted self-host builds use private inputs automatically. This list is an
// exception inbox: a row exists only after an external fork was blocked, so an
// operator never has to pre-register ordinary repositories.
const RepoConfigEditor = () => {
  const requests = useLoading(getPrivateInputForkRequests);
  const [busyRepo, setBusyRepo] = useState<string | null>(null);
  const [status, setStatus] = useState<string | null>(null);

  const setAllowed = async (
    request: PrivateInputForkRequest,
    allowed: boolean,
  ) => {
    const key = `${request.repoUser}/${request.repoName}#${request.forkFullName}`;
    const label = `${request.repoUser}/${request.repoName} (fork ${request.forkFullName})`;
    setStatus(null);
    setBusyRepo(key);
    const result = await setPrivateInputForkApproval(
      request.repoUser,
      request.repoName,
      request.forkFullName,
      allowed,
    );
    setBusyRepo(null);
    if (!result.ok) {
      setStatus(`Error saving ${label}: ${result.error.message}`);
      return;
    }
    setStatus(
      allowed
        ? `External-fork private inputs are allowed for ${label}. Retry the blocked build.`
        : `External-fork private-input approval revoked for ${label}.`,
    );
    requests.reload();
  };

  return (
    <div>
      <h2>External-fork private inputs</h2>
      <p className={styles.help}>
        Trusted pushes use private inputs automatically and their outputs go to
        the authenticated cache. A repository appears here only after an
        external fork requests private inputs and its build is blocked.
      </p>
      {requests.loading ? (
        <Loading />
      ) : !requests.data.ok ? (
        <p className={styles.error}>{requests.data.error.message}</p>
      ) : requests.data.data.length === 0 ? (
        <p className={styles.help}>No external-fork approvals requested.</p>
      ) : (
        <ul className={styles.requestList}>
          {requests.data.data.map((request) => {
            const repo = `${request.repoUser}/${request.repoName}`;
            const key = `${repo}#${request.forkFullName}`;
            return (
              <li key={key} className={styles.requestRow}>
                <div className={styles.requestDetails}>
                  <span className={styles.requestRepo}>{repo}</span>
                  <span className={styles.requestFork}>
                    Fork {request.forkFullName}
                  </span>
                  <span className={styles.requestTime}>
                    Blocked {request.blockedAt.toLocaleString()}
                  </span>
                </div>
                <span
                  className={`${styles.badge} ${
                    request.allowed ? styles.badgeAllowed : styles.badgeBlocked
                  }`}
                >
                  {request.allowed ? "Allowed" : "Blocked"}
                </span>
                <Button
                  style={request.allowed ? "warning" : "primary"}
                  loading={busyRepo === key}
                  onClick={() => setAllowed(request, !request.allowed)}
                >
                  {request.allowed ? "Revoke" : "Allow"}
                </Button>
              </li>
            );
          })}
        </ul>
      )}
      {status && <p className={styles.status}>{status}</p>}
    </div>
  );
};

export default RepoConfigEditor;
