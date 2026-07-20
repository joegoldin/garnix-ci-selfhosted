import fs from "node:fs";
import path from "node:path";

const styles = fs.readFileSync(
  path.join(__dirname, "styles.module.css"),
  "utf8",
);

describe("live build-log phase colors", () => {
  it("uses the success green for the label and pulsing dot", () => {
    expect(styles).toMatch(
      /\.phaseLive\s*{[^}]*color:\s*var\(--color-success\)/,
    );
    expect(styles).toMatch(
      /\.phaseLiveDot\s*{[^}]*background-color:\s*var\(--color-success\)/,
    );
  });
});
