export type Deferred<T> = {
  promise: Promise<T>;
  resolve: (t: T) => void;
  reject: () => void;
};

export const createDeferred = <T>(): Deferred<T> => {
  let resolve: (t: T) => void;
  let reject: () => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve: resolve!, reject: reject! };
};
