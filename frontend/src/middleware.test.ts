/** @jest-environment node */

import { NextRequest } from "next/server";
import { middleware } from "./middleware";

describe("middleware content security policy", () => {
  it("explicitly permits the request's same-origin secure websocket endpoint", () => {
    const response = middleware(
      new NextRequest("https://garnix.example:8443/servers/example/terminal"),
    );

    expect(response.headers.get("Content-Security-Policy")).toContain(
      "connect-src 'self' wss://garnix.example:8443 ",
    );
  });
});
