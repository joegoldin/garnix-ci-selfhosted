import "@testing-library/jest-dom";
import { fireEvent, render, screen, within } from "@testing-library/react";
import { ConfigureSettings } from "@/services/configure";
import {
  BuildRuntimeSettings,
  ConnectedDomainsSettings,
  parseMemoryGiB,
} from "./page";

jest.mock("../modules/configure/moduleInputs/repoPicker", () => ({
  RepoPicker: () => <div data-testid="repo-picker" />,
}));

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

describe("build runtime settings", () => {
  it("accepts only whole evaluation-memory values at or above 16 GiB", () => {
    expect(parseMemoryGiB("")).toBeNull();
    expect(parseMemoryGiB("15")).toBeNull();
    expect(parseMemoryGiB("16")).toBe(16);
    expect(parseMemoryGiB("16.5")).toBeNull();
  });

  it("shows the evaluation-memory default and per-repo override", () => {
    const settings: ConfigureSettings = {
      defaultBuildTimeoutMinutes: null,
      defaultMaxEvalMemoryGib: 16,
      repoOverrides: [
        {
          repoUser: "joegoldin",
          repoName: "dotfiles",
          buildTimeoutMinutes: 120,
          maxEvalMemoryGib: 32,
          defaultAuthentikApproved: false,
        },
      ],
      artifactRetentionDays: 30,
      artifactKeepLatest: false,
      artifactRepoOverrides: [],
      artifactUsage: [],
      lockedArtifactBuilds: [],
    };

    render(<BuildRuntimeSettings settings={settings} reload={jest.fn()} />);

    expect(
      screen.getByText("Default evaluation memory: 16 GiB"),
    ).toBeInTheDocument();
    expect(
      screen.queryByLabelText("Max evaluation memory (GiB)"),
    ).not.toBeInTheDocument();

    const row = within(rowFor("joegoldin/dotfiles"));
    fireEvent.click(row.getByRole("button", { name: "Edit" }));

    const memoryInput = screen.getByLabelText("Max evaluation memory (GiB)");
    expect(memoryInput).toHaveAttribute("min", "16");
    expect(memoryInput).toHaveValue(32);

    expect(row.getByText("2h")).toBeInTheDocument();
    expect(row.getByText("32 GiB")).toBeInTheDocument();
  });
});
