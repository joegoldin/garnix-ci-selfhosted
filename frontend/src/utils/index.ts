import { Ok, Result } from "@/services";
import { Duration, toMillis } from "./duration";

export const wait = (d: Duration): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, toMillis(d)));

export const mapValues = <Obj extends Record<string, unknown>, FnResult>(
  f: (i: Obj[keyof Obj], key: keyof Obj) => FnResult,
  x: Obj,
): { [key in keyof Obj]: FnResult } => {
  const result: Partial<{ [key in keyof Obj]: FnResult }> = {};
  for (const [key, value] of Object.entries(x) as Array<
    [keyof Obj, Obj[keyof Obj]]
  >) {
    result[key] = f(value, key);
  }
  return result as { [key in keyof Obj]: FnResult };
};

export const filterNull = <T>(list: Array<T | null>): Array<T> => {
  const result: Array<T> = [];
  for (const t of list) {
    if (t !== null) {
      result.push(t);
    }
  }
  return result;
};

export const mapCollectResult = <In, Out, Err>(
  f: (t: In) => Result<Out, Err>,
  arr: Array<In>,
): Result<Array<Out>, Err> => {
  const out: Array<Out> = [];
  for (const el of arr) {
    const result = f(el);
    if (!result.ok) return result;
    out.push(result.data);
  }
  return Ok(out);
};

/**
 * Prevents redirection to anything but a domain-relative path. This prevents
 * someone from constructing a url like
 * `https://garnix.io/login?page=https://evil.org`
 * (which could be uri encoded to make it less obvious)
 */
export const sanitizeRedirectPath = (path: string): string => {
  if (!path.match(/^[/][^/]/)) return "/";
  return path;
};
