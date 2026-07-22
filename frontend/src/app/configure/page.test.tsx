import "@testing-library/jest-dom";
import { render, screen, within } from "@testing-library/react";
import { ConnectedDomainsSettings } from "./page";

const rowFor = (domain: string): HTMLElement => {
  const row = screen.getByText(domain).closest("li");
  if (row == null) throw new Error(`No row found for ${domain}`);
  return row;
};

describe("connected domain settings", () => {
  it("shows status for every domain and actions only when applicable", () => {
    render(
      <ConnectedDomainsSettings
        domains={[
          {
            id: null,
            domain: "configured-ok.example",
            is_wildcard: true,
            verified: true,
            nix_configured: true,
          },
          {
            id: null,
            domain: "configured-pending.example",
            is_wildcard: true,
            verified: false,
            nix_configured: true,
          },
          {
            id: 1,
            domain: "manual-ok.example",
            is_wildcard: true,
            verified: true,
            nix_configured: false,
          },
          {
            id: 2,
            domain: "manual-pending.example",
            is_wildcard: true,
            verified: false,
            nix_configured: false,
          },
        ]}
        reload={jest.fn()}
      />,
    );

    const configuredOk = within(rowFor("configured-ok.example"));
    expect(configuredOk.getByText("resolves here")).toBeInTheDocument();
    expect(configuredOk.getByText("nix-configured")).toBeInTheDocument();
    expect(
      configuredOk.queryByRole("button", { name: "Verify" }),
    ).not.toBeInTheDocument();
    expect(
      configuredOk.queryByRole("button", { name: "Delete" }),
    ).not.toBeInTheDocument();

    const configuredPending = within(rowFor("configured-pending.example"));
    expect(configuredPending.getByText("not verified")).toBeInTheDocument();
    expect(
      configuredPending.getByRole("button", { name: "Verify" }),
    ).toBeInTheDocument();
    expect(
      configuredPending.queryByRole("button", { name: "Delete" }),
    ).not.toBeInTheDocument();

    const manualOk = within(rowFor("manual-ok.example"));
    expect(manualOk.getByText("resolves here")).toBeInTheDocument();
    expect(
      manualOk.queryByRole("button", { name: "Verify" }),
    ).not.toBeInTheDocument();
    expect(
      manualOk.getByRole("button", { name: "Delete" }),
    ).toBeInTheDocument();

    const manualPending = within(rowFor("manual-pending.example"));
    expect(manualPending.getByText("not verified")).toBeInTheDocument();
    expect(
      manualPending.getByRole("button", { name: "Verify" }),
    ).toBeInTheDocument();
    expect(
      manualPending.getByRole("button", { name: "Delete" }),
    ).toBeInTheDocument();
  });
});
