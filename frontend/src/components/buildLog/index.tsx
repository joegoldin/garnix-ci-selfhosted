"use client";

import Image from "next/image";
import React from "react";
import { Text } from "@/components/text";
import dashIcon from "@/components/icons/dash.svg";
import arrowRightIcon from "@/components/icons/arrow-right.svg";
import { Link } from "@/components/link";
import crossIcon from "@/components/icons/cross.svg";
import { BuildWithRelatedBuilds } from "@/services/build";
import { StatusIcon } from "@/components/statusIcon";
import { formatCommitSha } from "@/utils/format";
import { LogEntry, LogStream, useLogStream } from "@/hooks/useLogStream";
import { styleLines } from "@/utils/ansi";
import { Loading } from "@/components/loading";
import styles from "./styles.module.css";

export const RunLog = (props: { runId: string }) => {
  const logStream = useLogStream("run", props.runId);
  return <LogViewer logStream={logStream} defaultLogGroupName="Run" />;
};

export const BuildLog = ({ build }: { build: BuildWithRelatedBuilds }) => {
  const logStream = useLogStream("build", build.id);
  if (build.status !== "Pending" && build.original_build != null) {
    return (
      <>
        Build skipped since this package has already been built in a previous
        commit.
        <div className={styles.otherBuilds}>
          <Link href={`/build/${build.original_build.id}`}>
            <StatusIcon status={build.original_build.status} />
            {formatCommitSha(build.original_build)}
          </Link>
        </div>
      </>
    );
  }
  // Lines nix and the cache-upload step emit without a section tag (the
  // top-level "these N derivations will be built" plan and the
  // "Uploaded … to the garnix binary cache" lines) fall into the default
  // group. Name it after the package being built instead of "Unknown".
  return (
    <LogViewer
      logStream={logStream}
      defaultLogGroupName={build.package}
      failed={build.status === "Failure"}
    />
  );
};

const LogViewer = (props: {
  logStream: LogStream;
  defaultLogGroupName: string;
  failed?: boolean;
}) => {
  const { logs } = props.logStream;
  const [openLog, setOpenLog] = React.useState<string | undefined>();
  const firstLogGroupName = logs[0]?.[0];
  React.useEffect(() => {
    if (firstLogGroupName != null && logs.length === 1) {
      setOpenLog(firstLogGroupName);
    }
  }, [logs.length, firstLogGroupName]);
  const toggleLog = (logGroupName: string) => {
    setOpenLog(openLog !== logGroupName ? logGroupName : undefined);
  };
  const lastLogGroupName = logs[logs.length - 1]?.[0];
  return (
    <>
      {logs.map(([logGroupName, logs]) => {
        // While the stream is still going, only the last (most recent) group
        // is still live; every earlier group has already finished. Once the
        // whole stream is finished, every group has too.
        const isLive =
          props.logStream.loading && logGroupName === lastLogGroupName;
        // FOD checks (and similar) annotate a skipped phase in the group name,
        // e.g. "<drv> (skipped: source unavailable)". Label those "skipped"
        // rather than "finished" (same gray finished styling).
        const isSkipped = !isLive && logGroupName.includes("(skipped");
        const failedSuffix = " (failed)";
        const hasFailedSuffix = logGroupName.endsWith(failedSuffix);
        const isFailed =
          !isLive &&
          (hasFailedSuffix ||
            (props.failed && logGroupName === lastLogGroupName));
        const displayLogGroupName = hasFailedSuffix
          ? logGroupName.slice(0, -failedSuffix.length)
          : logGroupName;
        return (
          <div
            key={logGroupName}
            className={`${styles.log} ${openLog === logGroupName && styles.open}`}
          >
            <div
              className={styles.logHead}
              onClick={() => toggleLog(logGroupName)}
            >
              <div className={styles.logHeadTitle}>
                <Text>{displayLogGroupName || props.defaultLogGroupName}</Text>
                {isLive ? (
                  <span className={styles.phaseLive} title="Still streaming">
                    <span className={styles.phaseLiveDot} /> live
                  </span>
                ) : isFailed ? (
                  <span className={styles.phaseFailed} title="Failed">
                    × failed
                  </span>
                ) : isSkipped ? (
                  <span className={styles.phaseFinished} title="Skipped">
                    ✓ skipped
                  </span>
                ) : (
                  <span className={styles.phaseFinished} title="Finished">
                    ✓ finished
                  </span>
                )}
              </div>
              {openLog === logGroupName ? (
                <Image src={dashIcon} alt="close" className={styles.icon} />
              ) : (
                <Image src={crossIcon} alt="open" className={styles.icon} />
              )}
            </div>
            {openLog === logGroupName && (
              <AnsiLogViewer logs={logs} isLive={isLive} />
            )}
          </div>
        );
      })}
      {props.logStream.loading && (
        <div className={styles.loading}>
          <Loading />
        </div>
      )}
    </>
  );
};

const AnsiLogViewer = (props: { logs: Array<LogEntry>; isLive: boolean }) => {
  const styledLogs = React.useMemo(
    () => styleLines(props.logs.map(({ message }) => message)),
    [props.logs],
  );
  const bodyRef = React.useRef<HTMLDivElement>(null);
  const endRef = React.useRef<HTMLSpanElement>(null);
  const followsEndRef = React.useRef(false);
  const hasMeasuredRef = React.useRef(false);
  const lastMeasuredBottomRef = React.useRef<number | null>(null);
  const [showScrollToBottom, setShowScrollToBottom] = React.useState(false);

  const measureEndVisibility = React.useCallback(() => {
    const body = bodyRef.current;
    if (body == null) return;

    const bounds = body.getBoundingClientRect();
    const endIsVisible =
      bounds.bottom >= 0 && bounds.bottom <= window.innerHeight + 24;
    followsEndRef.current = endIsVisible;
    hasMeasuredRef.current = true;
    lastMeasuredBottomRef.current = bounds.bottom;
    setShowScrollToBottom(bounds.height > window.innerHeight && !endIsVisible);
  }, []);

  React.useEffect(() => {
    window.addEventListener("scroll", measureEndVisibility, { passive: true });
    window.addEventListener("resize", measureEndVisibility);
    return () => {
      window.removeEventListener("scroll", measureEndVisibility);
      window.removeEventListener("resize", measureEndVisibility);
    };
  }, [measureEndVisibility]);

  React.useLayoutEffect(() => {
    const body = bodyRef.current;
    const previousBottom = lastMeasuredBottomRef.current;
    if (
      body != null &&
      props.isLive &&
      hasMeasuredRef.current &&
      followsEndRef.current &&
      previousBottom != null
    ) {
      const growth = body.getBoundingClientRect().bottom - previousBottom;
      if (growth !== 0) {
        window.scrollBy({ behavior: "auto", left: 0, top: growth });
      }
      // Keep the expected post-scroll viewport position until the browser's
      // scroll event measures the actual one. This preserves any space the
      // viewer deliberately left below the log instead of snapping to an edge.
      lastMeasuredBottomRef.current = previousBottom;
    } else {
      measureEndVisibility();
    }
  }, [styledLogs.length, measureEndVisibility, props.isLive]);

  const scrollToBottom = () => {
    followsEndRef.current = true;
    endRef.current?.scrollIntoView({ behavior: "smooth", block: "center" });
  };

  return (
    <div className={styles.logBody} ref={bodyRef} data-testid="log-body">
      {showScrollToBottom ? (
        <button
          type="button"
          className={styles.scrollToBottom}
          aria-label="Scroll to latest log output"
          title="Scroll to latest log output"
          onClick={scrollToBottom}
        >
          <Image
            src={arrowRightIcon}
            alt=""
            aria-hidden="true"
            className={styles.scrollToBottomIcon}
          />
        </button>
      ) : null}
      <pre className={styles.logBodyInner}>
        {styledLogs.map((styledLogLine, index) => (
          <div key={index} className={styles.logLine}>
            <LogTimestamp timestamp={props.logs[index]?.timestamp} />
            <span>
              {styledLogLine.map(([style, text], idx) => (
                <span key={idx} style={style}>
                  {text}
                </span>
              ))}
            </span>
          </div>
        ))}
        <span ref={endRef} data-testid="log-end" aria-hidden="true" />
      </pre>
    </div>
  );
};

const LogTimestamp = ({ timestamp }: { timestamp?: string }) => {
  if (timestamp == null) return <span className={styles.logTimestamp} />;
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) {
    return <span className={styles.logTimestamp} />;
  }
  const label = date.toLocaleTimeString(undefined, {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  });
  return (
    <time
      className={styles.logTimestamp}
      dateTime={timestamp}
      title={timestamp}
    >
      {label}
    </time>
  );
};
