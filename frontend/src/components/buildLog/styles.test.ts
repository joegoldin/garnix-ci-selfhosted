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
      /\.phaseFailed\s*{[^}]*color:\s*var\(--color-error\)/,
    );
  });

  it("keeps a centered down-arrow control visible within a long log", () => {
    expect(styles).toMatch(
      /\.scrollToBottom\s*{[^}]*position:\s*sticky[^}]*display:\s*flex[^}]*align-items:\s*center[^}]*justify-content:\s*center[^}]*float:\s*right/,
    );
    expect(styles).toMatch(
      /\.scrollToBottomIcon\s*{[^}]*transform:\s*rotate\(90deg\)/,
    );
  });

  it("contains wide log lines in a local horizontal scroller", () => {
    expect(styles).toMatch(
      /\.logBody\s*{[^}]*max-width:\s*100%[^}]*overflow-x:\s*auto/,
    );
    expect(styles).toMatch(
      /\.logBodyInner\s*{[^}]*width:\s*max-content[^}]*min-width:\s*100%/,
    );
  });
});
