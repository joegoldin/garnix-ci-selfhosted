import "@testing-library/jest-dom";
import { render, screen } from "@testing-library/react";
import { BuildersSection } from "./page";

const stats = {
  load1: 0.5,
  load5: 0.4,
  load15: 0.3,
  memTotalBytes: 12 * 1024 ** 3,
  memUsedBytes: 3 * 1024 ** 3,
  diskTotalBytes: 100 * 1024 ** 3,
  diskAvailBytes: 60 * 1024 ** 3,
  cpuCount: 2,
  scraped: true,
};

describe("builder monitoring", () => {
  it("renders every configured builder with scheduler metadata", () => {
    render(
      <BuildersSection
        data={[
          {
            name: "erdtree",
            systems: ["x86_64-linux", "aarch64-linux"],
            maxJobs: 8,
            stats,
          },
          {
            name: "farum-azula",
            systems: ["aarch64-linux"],
            maxJobs: 1,
            stats,
          },
        ]}
      />,
    );

    expect(screen.getByText("Builders")).toBeInTheDocument();
    expect(screen.getByText("erdtree")).toBeInTheDocument();
    expect(screen.getByText("farum-azula")).toBeInTheDocument();
    expect(screen.getByText("farum-azula").closest("[id]"))
      .toHaveAttribute("id", "builder-farum-azula");
    expect(
      screen.getByText("x86_64-linux, aarch64-linux · 8 jobs"),
    ).toBeInTheDocument();
    expect(screen.getByText("aarch64-linux · 1 job")).toBeInTheDocument();
  });
});
