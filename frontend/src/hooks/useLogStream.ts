import React from "react";
import { getLogs } from "@/services/logs";
import { wait } from "@/utils";
import { fromSecs, double } from "@/utils/duration";

export type LogStream = {
  loading: boolean;
  logs: Array<[string, Array<LogEntry>]>;
};

export type LogEntry = {
  timestamp?: string;
  message: string;
};

export const useLogStream = (
  resourceType: "build" | "run",
  resourceId: string,
): LogStream => {
  const isMounted = React.useRef(true);
  const [loading, setLoading] = React.useState(true);
  const [logLines, setLogLines] = React.useState<
    Record<string, Array<LogEntry>>
  >({});
  React.useEffect(() => {
    void (async () => {
      let backoffInterval = fromSecs(1);
      const pollInterval = fromSecs(1);
      let after = undefined;
      while (true) {
        const response = await getLogs(resourceType, resourceId, after);
        if (!isMounted.current) return;
        if (response.ok) {
          const { logs, finished, max_page_size } = response.data;
          after = logs[logs.length - 1]?.timestamp ?? after;
          setLogLines((l) => {
            return logs.reduce(
              (acc: Record<string, Array<LogEntry>>, logLine) => {
                const phaseAndPackageName = [
                  logLine.package,
                  logLine.phase ? `(${logLine.phase})` : null,
                ]
                  .filter((i) => i != null)
                  .join(" ");
                return {
                  ...acc,
                  [phaseAndPackageName]: [
                    ...(acc[phaseAndPackageName] || []),
                    {
                      timestamp: logLine.timestamp,
                      message: logLine.log_message,
                    },
                  ],
                };
              },
              l,
            );
          });
          if (finished) {
            setLoading(false);
            return;
          }
          if (logs.length !== max_page_size) {
            // If the number of logs max out the page then we request the next
            // page ASAP, otherwise we're still streaming logs from the backend
            // and wait 1s
            await wait(pollInterval);
          }
        } else {
          backoffInterval = double(backoffInterval);
          await wait(backoffInterval);
        }
        if (!isMounted.current) return;
      }
    })();
    return () => {
      isMounted.current = false;
    };
  }, [resourceType, resourceId]);

  return React.useMemo(
    () => ({
      loading,
      logs: Object.entries(logLines),
    }),
    [logLines, loading],
  );
};
