import "@testing-library/jest-dom";
import { fireEvent, render, screen } from "@testing-library/react";
import { WaitingOn } from ".";

describe("WaitingOn", () => {
  it("renders a compact tree and expands one level at a time", () => {
    render(
      <WaitingOn
        nodes={[
          {
            id: "build:one",
            kind: "build",
            label: "scarab",
            href: "/build/one",
            detail: "running for 9m",
            startedAt: null,
            lastActivityAt: null,
            children: [
              {
                id: "builder:farum",
                kind: "builder",
                label: "farum-azula",
                href: "/monitoring#builder-farum-azula",
                detail: null,
                startedAt: null,
                lastActivityAt: null,
                children: [],
              },
            ],
          },
        ]}
      />,
    );

    expect(screen.getByText("Waiting on")).toBeInTheDocument();
    expect(screen.queryByText("farum-azula")).not.toBeInTheDocument();
    const expandButton = screen.getByRole("button", { name: /scarab/i });
    expect(expandButton.parentElement).toHaveStyle({ paddingLeft: "12px" });
    expect(screen.getByAltText("open")).toBeInTheDocument();

    fireEvent.click(expandButton);
    expect(screen.getByText("farum-azula")).toBeInTheDocument();
    expect(screen.getByAltText("close")).toBeInTheDocument();
  });

  it("shows active stages as running", () => {
    render(
      <WaitingOn
        nodes={[
          {
            id: "stage:one",
            kind: "stage",
            label: "Nix activity",
            href: null,
            detail: null,
            startedAt: new Date("2026-07-22T00:00:00Z"),
            lastActivityAt: new Date("2026-07-22T00:00:01Z"),
            children: [],
          },
        ]}
      />,
    );

    expect(screen.getByTitle("running")).toBeInTheDocument();
  });

  it("formats transfer bytes and omits an unknown zero total", () => {
    render(
      <WaitingOn
        nodes={[
          {
            id: "transfer:unknown",
            kind: "transfer",
            label: "downloading a path",
            href: null,
            detail: "36646462 / 0",
            startedAt: null,
            lastActivityAt: null,
            children: [],
          },
          {
            id: "transfer:known",
            kind: "transfer",
            label: "downloading another path",
            href: null,
            detail: "183349972 / 622655116",
            startedAt: null,
            lastActivityAt: null,
            children: [],
          },
        ]}
      />,
    );

    expect(screen.getByText("34.9 MiB")).toBeInTheDocument();
    expect(screen.getByText("174.9 MiB / 593.8 MiB")).toBeInTheDocument();
    expect(screen.queryByText(/\/ 0/)).not.toBeInTheDocument();
  });

  it("describes Nix realization as preparing store paths", () => {
    render(
      <WaitingOn
        nodes={[
          {
            id: "realize:one",
            kind: "realize",
            label: "",
            href: null,
            detail: null,
            startedAt: null,
            lastActivityAt: null,
            children: [],
          },
        ]}
      />,
    );

    expect(screen.getByText("prepare")).toBeInTheDocument();
    expect(screen.getByText("store paths")).toBeInTheDocument();
    expect(screen.queryByText("realize")).not.toBeInTheDocument();
  });
});
