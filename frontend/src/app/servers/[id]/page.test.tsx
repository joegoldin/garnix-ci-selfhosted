import "@testing-library/jest-dom";
import { render, screen } from "@testing-library/react";
import { MonitorContent } from "./page";

describe("server monitor summary", () => {
  it("shows resource values without redundant sample metadata", () => {
    const sampledAt = new Date("2026-07-22T04:00:00Z");
    const sample = {
      cpu_pct: 12.5,
      mem_used_kb: 1024 * 1024,
      mem_total_kb: 4 * 1024 * 1024,
      sampled_at: sampledAt,
    };

    render(<MonitorContent history={{ current: sample, samples: [sample] }} />);

    expect(screen.getByText("CPU")).toBeInTheDocument();
    expect(screen.getByText("Memory used")).toBeInTheDocument();
    expect(screen.queryByText("Samples")).not.toBeInTheDocument();
    expect(screen.queryByText("Last update")).not.toBeInTheDocument();
  });
});
