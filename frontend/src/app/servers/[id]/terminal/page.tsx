"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import "@xterm/xterm/css/xterm.css";
import { Button } from "@/components/button";
import { Link } from "@/components/link";
import { Text } from "@/components/text";
import { AppPage } from "@/utils/appPage";
import { useLoading } from "@/hooks/useLoading";
import { getRunningServers } from "@/services/servers";
import styles from "./styles.module.css";
import type { Terminal as XTerm } from "@xterm/xterm";

type ConnectionState =
  | { state: "connecting" }
  | { state: "connected" }
  | { state: "closed"; reason: string | null }
  | { state: "error" };

const connectionLabel = (connection: ConnectionState): string => {
  switch (connection.state) {
    case "connecting":
      return "Connecting…";
    case "connected":
      return "Connected";
    case "closed":
      return connection.reason
        ? `Disconnected (${connection.reason})`
        : "Disconnected";
    case "error":
      return "Connection error";
  }
};

const statusColor: Record<ConnectionState["state"], string> = {
  connecting: "#b4871c",
  connected: "green",
  closed: "#999",
  error: "red",
};

// Mirrors the backend's allowlist for the guest login user; the backend
// re-validates and rejects anything else before spawning ssh.
const USER_PATTERN = /^[a-z_][a-z0-9_-]{0,31}$/;

const DEFAULT_USER = "garnix";

const RETRY_DELAYS_MS = [500, 1_000, 2_000] as const;

const Page = ({ params }: { params: Record<string, string> }) => {
  const id = params.id!;
  const containerRef = useRef<HTMLDivElement | null>(null);
  const automaticRetryCount = useRef(0);
  const [connection, setConnection] = useState<ConnectionState>({
    state: "connecting",
  });
  const [attempt, setAttempt] = useState(0);
  // The login user the current/next connection uses, and the input draft.
  const [user, setUser] = useState(DEFAULT_USER);
  const [userDraft, setUserDraft] = useState(DEFAULT_USER);
  const userDraftValid = USER_PATTERN.test(userDraft);

  const serversResult = useLoading(getRunningServers);
  const server =
    !serversResult.loading && serversResult.data.ok
      ? (serversResult.data.data.find((s) => s.id === id) ?? null)
      : null;

  // Curated login-user suggestions from what garnix knows about this guest:
  // the deploy user (default), the exposed ssh login user when set, and the
  // guest's real login accounts captured at deploy time (getent passwd).
  // Filtered by the same pattern the backend re-validates, so a stray guest
  // account can't render an invalid chip.
  const userSuggestions = Array.from(
    new Set(
      [
        DEFAULT_USER,
        server?.exposed?.ssh_user ?? null,
        ...(server?.ssh_users ?? []),
      ].filter((u): u is string => u != null),
    ),
  ).filter((u) => USER_PATTERN.test(u));

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    let disposed = false;
    let term: XTerm | null = null;
    let socket: WebSocket | null = null;
    let onWindowResize: (() => void) | null = null;
    let retryTimer: number | null = null;
    let opened = false;
    let preOpenFailureHandled = false;

    const run = async () => {
      // xterm.js touches browser globals at import time, so load it only on
      // the client, inside the effect.
      const [{ Terminal }, { FitAddon }] = await Promise.all([
        import("@xterm/xterm"),
        import("@xterm/addon-fit"),
      ]);
      if (disposed) return;

      term = new Terminal({
        cursorBlink: true,
        fontSize: 14,
        scrollback: 4000,
      });
      const fitAddon = new FitAddon();
      term.loadAddon(fitAddon);
      term.open(container);
      fitAddon.fit();

      // Same-origin websocket: the browser sends the garnix session cookie
      // with the handshake; the backend re-verifies the session, checks that
      // this server belongs to the logged-in user, re-validates the login
      // user, and only then attaches a PTY running `ssh <user>@<guest>`.
      const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
      const query =
        user === DEFAULT_USER ? "" : `?user=${encodeURIComponent(user)}`;
      socket = new WebSocket(
        `${protocol}//${window.location.host}/api/terminal/${id}${query}`,
      );
      socket.binaryType = "arraybuffer";

      const handlePreOpenFailure = () => {
        if (disposed || opened || preOpenFailureHandled) return;
        preOpenFailureHandled = true;
        const delay = RETRY_DELAYS_MS[automaticRetryCount.current];
        if (delay == null) {
          setConnection({ state: "error" });
          return;
        }
        automaticRetryCount.current += 1;
        setConnection({ state: "connecting" });
        retryTimer = window.setTimeout(() => {
          if (!disposed) setAttempt((n) => n + 1);
        }, delay);
      };

      const sendResize = () => {
        if (term && socket && socket.readyState === WebSocket.OPEN) {
          socket.send(
            JSON.stringify({
              type: "resize",
              cols: term.cols,
              rows: term.rows,
            }),
          );
        }
      };

      socket.onopen = () => {
        if (disposed) return;
        opened = true;
        automaticRetryCount.current = 0;
        setConnection({ state: "connected" });
        fitAddon.fit();
        sendResize();
        term?.focus();
      };
      socket.onmessage = (event: MessageEvent) => {
        if (event.data instanceof ArrayBuffer) {
          term?.write(new Uint8Array(event.data));
        }
      };
      socket.onclose = (event: CloseEvent) => {
        if (disposed) return;
        if (!opened) {
          handlePreOpenFailure();
          return;
        }
        setConnection({ state: "closed", reason: event.reason || null });
        term?.write("\r\n\x1b[2m[connection closed]\x1b[0m\r\n");
      };
      socket.onerror = () => {
        if (disposed) return;
        if (opened) {
          setConnection({ state: "error" });
        } else {
          handlePreOpenFailure();
        }
      };

      // Keystrokes go to the PTY as binary frames; JSON control messages
      // (resize) go as text frames.
      const encoder = new TextEncoder();
      term.onData((data) => {
        if (socket && socket.readyState === WebSocket.OPEN) {
          socket.send(encoder.encode(data));
        }
      });
      term.onResize(sendResize);

      onWindowResize = () => fitAddon.fit();
      window.addEventListener("resize", onWindowResize);
    };
    void run();

    return () => {
      disposed = true;
      if (retryTimer != null) window.clearTimeout(retryTimer);
      if (onWindowResize) window.removeEventListener("resize", onWindowResize);
      socket?.close();
      term?.dispose();
    };
  }, [id, attempt, user]);

  const reconnect = useCallback(() => {
    automaticRetryCount.current = 0;
    setConnection({ state: "connecting" });
    setAttempt((n) => n + 1);
  }, []);

  const connectAs = useCallback((nextUser: string) => {
    if (!USER_PATTERN.test(nextUser)) return;
    automaticRetryCount.current = 0;
    setUserDraft(nextUser);
    setConnection({ state: "connecting" });
    // Changing the user re-runs the effect on its own; bump attempt too so
    // reconnecting with the same user still forces a fresh socket.
    setUser(nextUser);
    setAttempt((n) => n + 1);
  }, []);

  return (
    <div className={styles.container}>
      <Link href="/servers" className={styles.back}>
        ← Servers
      </Link>
      <Text type="h1" className={styles.h1}>
        {server ? `${server.repo_owner}/${server.repo_name}` : "Server"} —
        Terminal
      </Text>
      <div className={styles.statusRow}>
        <span
          className={styles.statusDot}
          style={{ backgroundColor: statusColor[connection.state] }}
        />
        <Text type="span" className={styles.statusText}>
          {connectionLabel(connection)}
          {server ? ` · ${server.package_name} · ${server.status}` : ""}
        </Text>
        {connection.state === "closed" || connection.state === "error" ? (
          <Button style="secondary" onClick={reconnect}>
            Reconnect
          </Button>
        ) : null}
      </div>
      <form
        className={styles.userRow}
        onSubmit={(e) => {
          e.preventDefault();
          connectAs(userDraft);
        }}
      >
        <label className={styles.userLabel} htmlFor="terminal-user">
          Login as
        </label>
        <input
          id="terminal-user"
          className={styles.userInput}
          value={userDraft}
          spellCheck={false}
          autoCapitalize="none"
          autoCorrect="off"
          onChange={(e) => setUserDraft(e.target.value)}
          aria-invalid={!userDraftValid}
        />
        {userSuggestions.map((suggestion) => (
          <button
            key={suggestion}
            type="button"
            className={styles.userChip}
            onClick={() => connectAs(suggestion)}
            data-active={suggestion === user}
          >
            {suggestion}
          </button>
        ))}
        <Button style="secondary" submit>
          Connect
        </Button>
      </form>
      {!userDraftValid ? (
        <Text type="p" className={styles.userError}>
          Usernames must match <code>^[a-z_][a-z0-9_-]{"{0,31}"}$</code>.
        </Text>
      ) : null}
      <div className={styles.terminalFrame}>
        <div ref={containerRef} className={styles.terminal} />
      </div>
      <Text type="p" className={styles.help}>
        A shell on your deployed server as the <code>{user}</code> user (default{" "}
        <code>{DEFAULT_USER}</code>). Login is still enforced by the
        server&apos;s own SSH keys. Sessions close after 10 minutes of
        inactivity (60 minutes maximum).
      </Text>
    </div>
  );
};

export default AppPage(Page, { requireAuth: true });
