import "@testing-library/jest-dom";
import { render, screen } from "@testing-library/react";
import Page from "./page";

const mockUseLoading = jest.fn();

jest.mock("../../../hooks/useLoading", () => ({
  useLoading: (...args: Array<unknown>) => mockUseLoading(...args),
}));

jest.mock("../../../components/build", () => ({
  CommitBuildsSummary: () => null,
}));

jest.mock("../../../components/statusIcon", () => ({
  StatusIcon: ({ status }: { status: string }) => (
    <span data-testid={`status-${status}`} />
  ),
}));

jest.mock("../../../components/waitingOn", () => ({
  WaitingOn: ({ nodes }: { nodes: Array<{ label: string }> }) => (
    <section data-testid="waiting-on">
      {nodes.map((node) => node.label).join(", ")}
    </section>
  ),
}));

const build = (id: string, status: string) => ({
  id,
  tag: "Build",
  status,
  package: id,
  packageType: "nixosConfiguration",
  system: null,
});

const rowFor = (name: string): Element => {
  const row = screen
    .getByText(`nixosConfiguration ${name}`)
    .closest("a")?.firstElementChild;
  if (row == null) throw new Error(`Could not find row for ${name}`);
  return row;
};

describe("commit row status colors", () => {
  it("tints running rows green and leaves completed rows neutral", () => {
    mockUseLoading
      .mockReturnValueOnce({
        loading: false,
        data: {
          ok: true,
          data: {
            summary: {
              repoUser: "owner",
              repoName: "repo",
              gitCommit: "0123456789abcdef",
              failed: 0,
              pending: 0,
              running: 0,
            },
            builds: [
              build("running", "Pending"),
              build("success", "Success"),
              build("skipped", "Skipped"),
              build("pending", "Pending"),
              build("failure", "Failure"),
            ],
            runs: [],
            running_build_ids: ["running"],
            waitingOn: [],
          },
        },
        reload: jest.fn(),
      })
      .mockReturnValueOnce({
        loading: false,
        data: {},
        reload: jest.fn(),
      });

    render(<Page params={{ slug: "0123456789abcdef" }} />);

    expect(rowFor("running")).toHaveClass("moduleRunning");
    expect(rowFor("success")).not.toHaveClass("moduleRunning");
    expect(rowFor("success")).not.toHaveClass("moduleSuccess");
    expect(rowFor("skipped")).not.toHaveClass("moduleRunning");
    expect(rowFor("skipped")).not.toHaveClass("moduleSuccess");
    expect(rowFor("pending")).toHaveClass("modulePending");
    expect(rowFor("failure")).toHaveClass("moduleFailed");
  });
});

describe("commit wait state", () => {
  it("shows the expandable wait tree above the build rows", () => {
    mockUseLoading
      .mockReturnValueOnce({
        loading: false,
        data: {
          ok: true,
          data: {
            summary: {
              repoUser: "owner",
              repoName: "repo",
              gitCommit: "0123456789abcdef",
              failed: 0,
              pending: 1,
              running: 0,
            },
            builds: [build("pending", "Pending")],
            runs: [],
            running_build_ids: [],
            waitingOn: [
              {
                id: "build:pending",
                kind: "build",
                label: "nixosConfiguration pending",
                detail: "Pending",
                href: "/build/pending",
                startedAt: null,
                lastActivityAt: null,
                children: [],
              },
            ],
          },
        },
        reload: jest.fn(),
      })
      .mockReturnValueOnce({
        loading: false,
        data: {},
        reload: jest.fn(),
      });

    render(<Page params={{ slug: "0123456789abcdef" }} />);

    const waitTree = screen.getByTestId("waiting-on");
    const buildRow = screen
      .getAllByText("nixosConfiguration pending")
      .find((element) => !waitTree.contains(element));
    expect(buildRow).toBeDefined();
    expect(waitTree).toHaveTextContent("nixosConfiguration pending");
    expect(
      waitTree.compareDocumentPosition(buildRow as Element) &
        Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy();
  });
});
