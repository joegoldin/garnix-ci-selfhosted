import "@testing-library/jest-dom";
import { act, fireEvent, render, screen } from "@testing-library/react";
import { useLogStream } from "../../hooks/useLogStream";
import { BuildLog, RunLog } from ".";

jest.mock("../../hooks/useLogStream", () => ({
  useLogStream: jest.fn(),
}));

const mockedUseLogStream = jest.mocked(useLogStream);

describe("build log phase status", () => {
  beforeEach(() => {
    mockedUseLogStream.mockReset();
  });

  it("marks the final phase of a failed build as failed", () => {
    mockedUseLogStream.mockReturnValue({
      loading: false,
      logs: [["farum-azula", ["evaluation failed"]]],
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
      logs: [["/nix/store/example.drv (failed)", ["FOD failed"]]],
    });

    render(<RunLog runId="run-id" />);

    expect(screen.getByText("/nix/store/example.drv")).toBeInTheDocument();
    expect(screen.queryByText(/\(failed\)/)).not.toBeInTheDocument();
    expect(screen.getByText("× failed")).toHaveClass("phaseFailed");
  });

  it("offers a sticky jump to the bottom of a long expanded log", () => {
    mockedUseLogStream.mockReturnValue({
      loading: false,
      logs: [["long phase", ["first", "last"]]],
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
      block: "end",
    });
  });

  it("follows live output only while the log end is visible", () => {
    const initialLogs: Array<[string, Array<string>]> = [
      ["live phase", ["first"]],
    ];
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
    const scrollIntoView = jest.fn();
    Object.defineProperty(logEnd, "scrollIntoView", {
      configurable: true,
      value: scrollIntoView,
    });
    act(() => window.dispatchEvent(new Event("scroll")));

    mockedUseLogStream.mockReturnValue({
      loading: true,
      logs: [["live phase", ["first", "second"]]],
    });
    view.rerender(<RunLog runId="run-id" />);
    expect(scrollIntoView).toHaveBeenCalledWith({ block: "end" });

    scrollIntoView.mockClear();
    bounds.bottom = 1400;
    act(() => window.dispatchEvent(new Event("scroll")));
    mockedUseLogStream.mockReturnValue({
      loading: true,
      logs: [["live phase", ["first", "second", "third"]]],
    });
    view.rerender(<RunLog runId="run-id" />);
    expect(scrollIntoView).not.toHaveBeenCalled();
  });
});
