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
  const isMounted = React.useRef(true);
  const [state, setState] = React.useState<Loading<T>>({
    loading: true,
  });
  const reloadDeferred = React.useRef<Deferred<void> | null>(null);
  React.useEffect(() => {
    void (async () => {
      while (true) {
        reloadDeferred.current = createDeferred();
        const result = await loader();
        if (!isMounted.current) return;
        setState({ loading: false, data: result });
        if (
          opts.poll != null &&
          (opts.shouldPoll == null || opts.shouldPoll(result))
        ) {
          await Promise.race([wait(opts.poll), reloadDeferred.current.promise]);
        } else {
          await reloadDeferred.current.promise;
        }
        if (!isMounted.current) return;
      }
    })();
    return () => {
      isMounted.current = false;
    };
    // Disabling exhaustive-deps because we need `toMillis` to make `Duration`
    // stable, but eslint does not understand that.
    //
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loader, opts.poll && toMillis(opts.poll)]);
  return { ...state, reload: () => reloadDeferred.current!.resolve() };
};
