import { TextEncoder } from "util";
import "@testing-library/jest-dom";
import { act, render, waitFor } from "@testing-library/react";
import Page from "./page";

jest.mock("../../../../utils/appPage", () => ({
  AppPage: (component: unknown) => component,
}));

jest.mock("../../../../hooks/useLoading", () => ({
  useLoading: () => ({ loading: true }),
}));

jest.mock("../../../../services/servers", () => ({
  getRunningServers: jest.fn(),
}));

jest.mock("../../../../components/button", () => ({
  Button: ({
    children,
    submit,
    style: _style,
    ...props
  }: React.PropsWithChildren<
    Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, "style"> & {
      style?: string;
      submit?: boolean;
    }
  >) => (
    <button type={submit ? "submit" : "button"} {...props}>
      {children}
    </button>
  ),
}));

jest.mock("../../../../components/link", () => ({
  Link: ({
    children,
    href,
    ...props
  }: React.PropsWithChildren<
    React.AnchorHTMLAttributes<HTMLAnchorElement> & { href: string }
  >) => (
    <a href={href} {...props}>
      {children}
    </a>
  ),
}));

jest.mock("../../../../components/text", () => ({
  Text: ({
    children,
    type,
    ...props
  }: React.PropsWithChildren<
    React.HTMLAttributes<HTMLElement> & { type: string }
  >) => {
    const Tag = type === "h1" ? "h1" : type === "p" ? "p" : "span";
    return <Tag {...props}>{children}</Tag>;
  },
}));

const terminalDispose = jest.fn();

jest.mock("@xterm/xterm", () => ({
  Terminal: class {
    cols = 80;
    rows = 24;
    dispose = terminalDispose;
    focus = jest.fn();
    loadAddon = jest.fn();
    onData = jest.fn();
    onResize = jest.fn();
    open = jest.fn();
    write = jest.fn();
  },
}));

jest.mock("@xterm/addon-fit", () => ({
  FitAddon: class {
    fit = jest.fn();
  },
}));

class FakeWebSocket {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;
  static instances: FakeWebSocket[] = [];

  binaryType = "";
  readyState = FakeWebSocket.CONNECTING;
  onopen: (() => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onclose: ((event: CloseEvent) => void) | null = null;
  onerror: (() => void) | null = null;

  constructor(readonly url: string) {
    FakeWebSocket.instances.push(this);
  }

  close() {
    this.readyState = FakeWebSocket.CLOSED;
  }

  send() {}

  failHandshake() {
    this.readyState = FakeWebSocket.CLOSED;
    this.onerror?.();
    this.onclose?.({ code: 1006, reason: "", wasClean: false } as CloseEvent);
  }
}

describe("server terminal connection", () => {
  beforeEach(() => {
    FakeWebSocket.instances = [];
    terminalDispose.mockClear();
    Object.defineProperty(window, "WebSocket", {
      configurable: true,
      value: FakeWebSocket,
    });
    Object.defineProperty(global, "WebSocket", {
      configurable: true,
      value: FakeWebSocket,
    });
    Object.defineProperty(global, "TextEncoder", {
      configurable: true,
      value: TextEncoder,
    });
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it("retries an abnormal pre-handshake failure three times with bounded backoff", async () => {
    render(<Page params={{ id: "Dqgxm0lz" }} />);
    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1));
    jest.useFakeTimers();

    act(() => FakeWebSocket.instances[0]!.failHandshake());
    act(() => jest.advanceTimersByTime(499));
    expect(FakeWebSocket.instances).toHaveLength(1);
    act(() => jest.advanceTimersByTime(1));
    await act(async () => {});
    expect(FakeWebSocket.instances).toHaveLength(2);

    act(() => FakeWebSocket.instances[1]!.failHandshake());
    act(() => jest.advanceTimersByTime(999));
    expect(FakeWebSocket.instances).toHaveLength(2);
    act(() => jest.advanceTimersByTime(1));
    await act(async () => {});
    expect(FakeWebSocket.instances).toHaveLength(3);

    act(() => FakeWebSocket.instances[2]!.failHandshake());
    act(() => jest.advanceTimersByTime(1999));
    expect(FakeWebSocket.instances).toHaveLength(3);
    act(() => jest.advanceTimersByTime(1));
    await act(async () => {});
    expect(FakeWebSocket.instances).toHaveLength(4);

    act(() => FakeWebSocket.instances[3]!.failHandshake());
    act(() => jest.advanceTimersByTime(60_000));
    await act(async () => {});
    expect(FakeWebSocket.instances).toHaveLength(4);
  });
});
