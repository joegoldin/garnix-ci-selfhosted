import React from "react";
import { wait } from "@/utils";
import { Duration, toMillis } from "@/utils/duration";
import { Deferred, createDeferred } from "@/utils/deferred";

export type Loading<T> =
  | { loading: true }
  | { loading: false; readonly data: T };

export type UtilityMethods = {
  reload: () => void;
};

export type LoadOptions<T> = {
  poll?: Duration;
  shouldPoll?: (t: T) => boolean;
};

export const useLoading = <T>(
  loader: () => Promise<T>,
  opts: LoadOptions<T> = {},
): Loading<T> & UtilityMethods => {
  const [state, setState] = React.useState<Loading<T>>({
    loading: true,
  });
  const reloadDeferred = React.useRef<Deferred<void> | null>(null);
  React.useEffect(() => {
    // Cancellation is scoped to THIS effect run. A shared `isMounted` ref stayed
    // `false` after the first cleanup, so when `loader` changed (its deps
    // updated - e.g. a fetch that keys off async-loaded state) the re-run
    // fetched correctly but the guard swallowed its `setState`, leaving the old
    // result stuck. A per-run local flag lets a new loader re-fetch while only
    // the old run stops.
    let cancelled = false;
    void (async () => {
      while (true) {
        reloadDeferred.current = createDeferred();
        const result = await loader();
        if (cancelled) return;
        setState({ loading: false, data: result });
        if (
          opts.poll != null &&
          (opts.shouldPoll == null || opts.shouldPoll(result))
        ) {
          await Promise.race([wait(opts.poll), reloadDeferred.current.promise]);
        } else {
          await reloadDeferred.current.promise;
        }
        if (cancelled) return;
      }
    })();
    return () => {
      cancelled = true;
    };
    // Disabling exhaustive-deps because we need `toMillis` to make `Duration`
    // stable, but eslint does not understand that.
    //
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loader, opts.poll && toMillis(opts.poll)]);
  return { ...state, reload: () => reloadDeferred.current!.resolve() };
};
