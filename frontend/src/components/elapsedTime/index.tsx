"use client";

import React from "react";
import { diffTime, formatDurationShort } from "@/utils/duration";

type Props = {
  start: Date;
  end: Date | null;
  running: boolean;
};

/**
 * The "Total time" for a build or run: a static total (end − start) once it
 * has finished, a live counter (now − start) that ticks up while it is
 * running, and "-" before it has started. The running and finished states
 * share `formatDurationShort` so the counter reads the same as the final time.
 */
export const ElapsedTime = ({ start, end, running }: Props) => {
  const now = useNow(running);
  if (end) return <>{formatDurationShort(diffTime(end, start))}</>;
  if (running) return <>{formatDurationShort(diffTime(now, start))}</>;
  return <>-</>;
};

/**
 * Returns the current time, re-rendering about once a second while `active`.
 * The interval is cleared when `active` goes false or the component unmounts,
 * so there are no leaked timers and no state updates after unmount.
 */
const useNow = (active: boolean): Date => {
  const [now, setNow] = React.useState(() => new Date());
  React.useEffect(() => {
    if (!active) return;
    setNow(new Date());
    const id = setInterval(() => setNow(new Date()), 1000);
    return () => clearInterval(id);
  }, [active]);
  return now;
};
