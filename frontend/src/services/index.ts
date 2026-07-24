import { ZodTypeDef, z } from "zod";
import { formatZodError } from "@/utils/zod";

export type Ok<T> = { ok: true; data: T };
export type Err<E> = { ok: false; error: E };
export type Result<T, E = { message: string }> = Ok<T> | Err<E>;

export const Ok = <T>(data: T): Ok<T> => ({ ok: true, data });
export const Err = <E>(error: E): Err<E> => ({ ok: false, error });

export type APIError = {
  path: string;
  reason: "not-ok" | "server-error" | "schema-invalid";
  message: string;
  status: number | "parse-error";
};

export type APIResult<T> = Result<T, APIError>;

export const fetchFromAPI = async <Input, Output>(
  schema: z.Schema<Output, ZodTypeDef, Input>,
  method: "GET" | "POST" | "DELETE" | "PUT",
  path: string,
  options?: {
    query?: URLSearchParams | Record<string, string>;
    body?: BodyInit;
    apiOrigin?: string;
  },
): Promise<APIResult<Output>> => {
  let url = `${options?.apiOrigin || ""}/api/${path}`;
  if (method === "GET" && options?.query)
    url += `?${new URLSearchParams(options.query).toString()}`;
  const finalOptions: RequestInit = {
    ...(options || {}),
    method,
    // When our oauth2-proxy session has expired, the gateway answers every API
    // call with a cross-origin 3xx to the SSO login. A same-origin `fetch` can't
    // complete an OAuth flow (CSP blocks the authorize endpoint), so following
    // the redirect throws a bare "NetworkError". `manual` turns it into an
    // opaque redirect we detect below and report clearly instead. Every route
    // reached here returns JSON/204; the only redirecting routes (artifact
    // downloads) are plain hrefs, never fetched — so an opaque redirect here
    // always means the session expired.
    redirect: "manual",
  };
  if ((method === "POST" || method === "PUT") && finalOptions?.body)
    finalOptions.headers = {
      ...finalOptions.headers,
      "Content-Type": "application/json",
    };
  const response = await fetch(url, finalOptions);
  if (response.type === "opaqueredirect")
    return Err({
      path,
      reason: "not-ok",
      message: "Your session expired — refresh the page to sign in again.",
      status: 401,
    });
  const rawBody = await response.text();
  const body = safeParseJson(rawBody);
  if (!response.ok) {
    return Err({
      path,
      reason: "not-ok",
      message: body.message || rawBody || response.statusText || "error",
      status: response.status,
    });
  }
  const verifiedResponse = schema.safeParse(body);
  if (!verifiedResponse.success)
    return Err({
      path,
      reason: "schema-invalid",
      message: formatZodError(verifiedResponse.error),
      status: "parse-error",
    });
  return Ok(verifiedResponse.data);
};

const safeParseJson = (text: string): any => {
  try {
    return JSON.parse(text);
  } catch {
    return {};
  }
};
