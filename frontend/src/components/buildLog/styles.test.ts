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

  it("keeps a centered down-arrow control sticky within a long log", () => {
    expect(styles).toMatch(
      /\.scrollToBottom\s*{[^}]*position:\s*sticky[^}]*display:\s*flex[^}]*align-items:\s*center[^}]*justify-content:\s*center[^}]*float:\s*right/,
    );
    expect(styles).toMatch(
      /\.scrollToBottomIcon\s*{[^}]*transform:\s*rotate\(90deg\)/,
    );
  });

  it("wraps wide log lines without creating a sticky-breaking scroller", () => {
    expect(styles).toMatch(
      /\.logBody\s*{[^}]*max-width:\s*100%[^}]*overflow-x:\s*clip/,
    );
    expect(styles).toMatch(
      /\.logBodyInner\s*{[^}]*width:\s*100%[^}]*white-space:\s*pre-wrap[^}]*overflow-wrap:\s*anywhere/,
    );
    expect(styles).toMatch(
      /\.logLine\s*{[^}]*grid-template-columns:\s*5\.5rem minmax\(0,\s*1fr\)/,
    );
  });
});
