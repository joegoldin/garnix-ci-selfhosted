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
    fireEvent.click(screen.getByRole("button", { name: /scarab/i }));
    expect(screen.getByText("farum-azula")).toBeInTheDocument();
  });
});
