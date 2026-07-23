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

  it("uses the failure red for failed phases", () => {
    expect(styles).toMatch(
      /\.phaseFailed\s*{[^}]*color:\s*var\(--color-failure\)/,
    );
  });

  it("keeps the scroll-to-bottom control visible within a long log", () => {
    expect(styles).toMatch(
      /\.scrollToBottom\s*{[^}]*position:\s*sticky[^}]*float:\s*right/,
    );
  });
});
