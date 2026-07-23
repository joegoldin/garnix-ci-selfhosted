import "@testing-library/jest-dom";
import { act, fireEvent, render, screen } from "@testing-library/react";
import { useLogStream } from "../../hooks/useLogStream";
import { BuildLog, RunLog } from ".";

jest.mock("../../hooks/useLogStream", () => ({
  useLogStream: jest.fn(),
}));

const mockedUseLogStream = jest.mocked(useLogStream);
const lines = (...messages: Array<string>) =>
  messages.map((message) => ({ message }));

describe("build log phase status", () => {
  beforeEach(() => {
    mockedUseLogStream.mockReset();
  });

  it("marks the final phase of a failed build as failed", () => {
    mockedUseLogStream.mockReturnValue({
      loading: false,
      logs: [["farum-azula", lines("evaluation failed")]],
    });

    render(
      <BuildLog
        build={
          {
            id: "build-id",
            package: "farum-azula",
            status: "Failure",
            original_build: undefined,
          } as never
        }
      />,
    );

    expect(screen.getByText("× failed")).toHaveClass("phaseFailed");
    expect(screen.queryByText("✓ finished")).not.toBeInTheDocument();
  });

  it("uses an encoded FOD failure as status instead of title text", () => {
    mockedUseLogStream.mockReturnValue({
      loading: false,
      logs: [["/nix/store/example.drv (failed)", lines("FOD failed")]],
    });

    render(<RunLog runId="run-id" />);

    expect(screen.getByText("/nix/store/example.drv")).toBeInTheDocument();
    expect(screen.queryByText(/\(failed\)/)).not.toBeInTheDocument();
    expect(screen.getByText("× failed")).toHaveClass("phaseFailed");
  });

  it("shows each log line's durable event timestamp", () => {
    mockedUseLogStream.mockReturnValue({
      loading: false,
      logs: [
        [
          "evaluation",
          [
            {
              timestamp: "2026-07-22T12:34:56Z",
              message: "evaluating package",
            },
          ],
        ],
      ],
    });

    render(<RunLog runId="run-id" />);

    const timestamp = screen.getByTitle("2026-07-22T12:34:56Z");
    expect(timestamp.tagName).toBe("TIME");
    expect(timestamp).toHaveAttribute("datetime", "2026-07-22T12:34:56Z");
    expect(timestamp).toHaveTextContent(/^\d{2}:\d{2}:\d{2}$/);
    expect(screen.getByText("evaluating package")).toBeInTheDocument();
  });

  it("offers a sticky jump to the bottom of a long expanded log", () => {
    mockedUseLogStream.mockReturnValue({
      loading: false,
      logs: [["long phase", lines("first", "last")]],
    });

    render(<RunLog runId="run-id" />);

    const logBody = screen.getByTestId("log-body");
    const logEnd = screen.getByTestId("log-end");
    Object.defineProperty(window, "innerHeight", {
      configurable: true,
      value: 800,
    });
    jest.spyOn(logBody, "getBoundingClientRect").mockReturnValue({
      bottom: 1400,
      height: 1200,
    } as DOMRect);
    const scrollIntoView = jest.fn();
    Object.defineProperty(logEnd, "scrollIntoView", {
      configurable: true,
      value: scrollIntoView,
    });

    act(() => window.dispatchEvent(new Event("scroll")));

    fireEvent.click(
      screen.getByRole("button", { name: "Scroll to latest log output" }),
    );
    expect(scrollIntoView).toHaveBeenCalledWith({
      behavior: "smooth",
      block: "center",
    });
    expect(
      screen
        .getByRole("button", { name: "Scroll to latest log output" })
        .querySelector("img"),
    ).toHaveClass("scrollToBottomIcon");
  });

  it("preserves the viewport offset while following visible live output", () => {
    const initialLogs = [["live phase", lines("first")]] satisfies Array<
      [string, ReturnType<typeof lines>]
    >;
    mockedUseLogStream.mockReturnValue({ loading: true, logs: initialLogs });

    const view = render(<RunLog runId="run-id" />);
    const logBody = screen.getByTestId("log-body");
    const logEnd = screen.getByTestId("log-end");
    Object.defineProperty(window, "innerHeight", {
      configurable: true,
      value: 800,
    });
    const bounds = { bottom: 700, height: 1200 };
    jest
      .spyOn(logBody, "getBoundingClientRect")
      .mockImplementation(() => bounds as DOMRect);
    const scrollBy = jest.fn();
    Object.defineProperty(window, "scrollBy", {
      configurable: true,
      value: scrollBy,
    });
    const scrollIntoView = jest.fn();
    Object.defineProperty(logEnd, "scrollIntoView", {
      configurable: true,
      value: scrollIntoView,
    });
    act(() => window.dispatchEvent(new Event("scroll")));

    mockedUseLogStream.mockReturnValue({
      loading: true,
      logs: [["live phase", lines("first", "second")]],
    });
    bounds.bottom = 760;
    view.rerender(<RunLog runId="run-id" />);
    expect(scrollBy).toHaveBeenCalledWith({
      behavior: "auto",
      left: 0,
      top: 60,
    });
    expect(scrollIntoView).not.toHaveBeenCalled();

    scrollBy.mockClear();
    bounds.bottom = 1400;
    act(() => window.dispatchEvent(new Event("scroll")));
    mockedUseLogStream.mockReturnValue({
      loading: true,
      logs: [["live phase", lines("first", "second", "third")]],
    });
    view.rerender(<RunLog runId="run-id" />);
    expect(scrollBy).not.toHaveBeenCalled();
  });

  it("preserves the horizontal offset while following the visible line end", () => {
    mockedUseLogStream.mockReturnValue({
      loading: true,
      logs: [["live phase", lines("first")]],
    });

    const view = render(<RunLog runId="run-id" />);
    const logBody = screen.getByTestId("log-body");
    const dimensions = { clientWidth: 400, scrollWidth: 1_000 };
    Object.defineProperty(logBody, "clientWidth", {
      configurable: true,
      get: () => dimensions.clientWidth,
    });
    Object.defineProperty(logBody, "scrollWidth", {
      configurable: true,
      get: () => dimensions.scrollWidth,
    });
    logBody.scrollLeft = 590;
    act(() => logBody.dispatchEvent(new Event("scroll")));

    mockedUseLogStream.mockReturnValue({
      loading: true,
      logs: [["live phase", lines("first", "a wider second line")]],
    });
    dimensions.scrollWidth = 1_120;
    view.rerender(<RunLog runId="run-id" />);
    expect(logBody.scrollLeft).toBe(710);

    logBody.scrollLeft = 400;
    act(() => logBody.dispatchEvent(new Event("scroll")));
    mockedUseLogStream.mockReturnValue({
      loading: true,
      logs: [["live phase", lines("first", "a wider second line", "third")]],
    });
    dimensions.scrollWidth = 1_240;
    view.rerender(<RunLog runId="run-id" />);
    expect(logBody.scrollLeft).toBe(400);
  });
});
