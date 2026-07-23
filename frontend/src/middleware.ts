import { NextRequest, NextResponse } from "next/server";

export function middleware(request: NextRequest) {
  const nonce = Buffer.from(crypto.randomUUID()).toString("base64");
  const websocketScheme =
    request.nextUrl.protocol === "https:" ? "wss:" : "ws:";
  // request.nextUrl.host derives from the client-controlled Host header, so it
  // must not be interpolated into the CSP verbatim: a malformed value could
  // inject extra directives or widen connect-src. Only reflect a well-formed
  // host[:port] (a spoofed-but-valid host is harmless — it just names the
  // client's own same-origin websocket); anything else falls back to 'self'.
  const rawHost = request.nextUrl.host;
  const sameOriginWebsocket = /^[a-zA-Z0-9.-]+(:\d+)?$/.test(rawHost)
    ? `${websocketScheme}//${rawHost}`
    : "";
  const contentSecurityPolicy = [
    `default-src 'none'`,
    `connect-src ${[
      "'self'",
      sameOriginWebsocket,
      "https://maps.googleapis.com",
      "https://api.github.com",
    ]
      .filter(Boolean)
      .join(" ")}`,
    `script-src ${[
      "'self'",
      `'nonce-${nonce}'`,
      ...(process.env.NODE_ENV !== "production" ? ["'unsafe-eval'"] : []),
      "https://maps.googleapis.com",
    ].join(" ")}`,
    `frame-src https://www.loom.com`,
    `style-src 'self' 'unsafe-inline'`,
    `img-src 'self' https: blob: data:`,
    `font-src 'self'`,
    `media-src 'self'`,
    `object-src 'none'`,
    `base-uri 'none'`,
    `form-action 'self' https://github.com`,
    `frame-ancestors 'none'`,
  ].join(";");
  const requestHeaders = new Headers(request.headers);
  requestHeaders.set("x-nonce", nonce);
  const response = NextResponse.next({
    request: {
      headers: requestHeaders,
    },
  });

  response.headers.set("Content-Security-Policy", contentSecurityPolicy);
  response.headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
  response.headers.set("X-Content-Type-Options", "nosniff");
  response.headers.set("X-Frame-Options", "DENY");

  return response;
}
