import "@testing-library/jest-dom";
import { fireEvent, render, screen } from "@testing-library/react";
import { RunPage } from ".";

jest.mock("../buildLog", () => ({ RunLog: () => null }));
jest.mock("../statusIcon", () => ({ StatusIcon: () => null }));

describe("run waiting state", () => {
  it("keeps the cancel action in the title row and expands waiting levels", () => {
    render(
      <RunPage
        run={
          {
            id: "run-id",
            tag: "Run",
            name: "FOD checks",
            repoUser: "owner",
            repoName: "repo",
            repo_user: "owner",
            repo_name: "repo",
            gitCommit: "aaaaaaaa",
            git_commit: "aaaaaaaa",
            branch: "main",
            status: "Running",
            startTime: new Date("2026-07-22T00:00:00Z"),
            start_time: new Date("2026-07-22T00:00:00Z"),
            endTime: null,
            runStartedAt: new Date("2026-07-22T00:00:01Z"),
            run_started_at: new Date("2026-07-22T00:00:01Z"),
            waitingOn: [
              {
                id: "build:one",
                kind: "build",
                label: "nixosConfiguration scarab",
                href: "/build/one",
                detail: null,
                startedAt: null,
                lastActivityAt: null,
                children: [
                  {
                    id: "stage:one",
                    kind: "stage",
                    label: "Building on farum-azula",
                    href: null,
                    detail: null,
                    startedAt: null,
                    lastActivityAt: null,
                    children: [],
                  },
                ],
              },
            ],
          } as never
        }
      />,
    );

    const heading = screen.getByRole("heading", { name: /FOD checks/i });
    const cancel = screen.getByRole("button", { name: "Cancel run" });
    expect(heading.parentElement).toBe(cancel.closest("form")?.parentElement);

    expect(screen.queryByText("Building on farum-azula")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /nixosConfiguration scarab/i }));
    expect(screen.getByText("Building on farum-azula")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /nixosConfiguration scarab/i })).toHaveAttribute(
      "href",
      "/build/one",
    );
  });
});
