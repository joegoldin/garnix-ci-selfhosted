import { forgeBranchUrl, forgeCommitUrl, forgeRepoUrl } from "./forge";
import { formatCommitSha, isManualCommit } from "./format";

const MANUAL = "manual-20260726-020334";
const SHA = "6c62b6e5a1c0ffee0123456789abcdef01234567";

describe("manual commits", () => {
  describe("isManualCommit", () => {
    it("recognizes the synthetic id and nothing else", () => {
      expect(isManualCommit(MANUAL)).toBe(true);
      expect(isManualCommit(SHA)).toBe(false);
      // Not a prefix match on a real SHA that merely contains the word.
      expect(isManualCommit("abcmanual-123")).toBe(false);
    });
  });

  describe("formatCommitSha", () => {
    it("keeps a manual id whole — truncating gives the useless 'manual-2'", () => {
      expect(formatCommitSha({ gitCommit: MANUAL })).toBe(MANUAL);
    });

    it("still shortens a real SHA to 8 characters", () => {
      expect(formatCommitSha({ gitCommit: SHA })).toBe("6c62b6e5");
    });
  });

  describe("forgeCommitUrl", () => {
    it("has no forge URL for a manual id (it is not a ref, so a link 404s)", () => {
      expect(forgeCommitUrl("github", "", "o", "r", MANUAL)).toBeUndefined();
      expect(
        forgeCommitUrl("gitea", "https://gitea.example", "o", "r", MANUAL),
      ).toBeUndefined();
    });

    it("still links real commits on both forges", () => {
      expect(forgeCommitUrl("github", "", "o", "r", SHA)).toBe(
        `https://github.com/o/r/commit/${SHA}`,
      );
      expect(
        forgeCommitUrl("gitea", "https://gitea.example", "o", "r", SHA),
      ).toBe(`https://gitea.example/o/r/commit/${SHA}`);
    });

    it("leaves the other forge URL builders alone", () => {
      expect(forgeRepoUrl("github", "", "o", "r")).toBe(
        "https://github.com/o/r",
      );
      expect(forgeBranchUrl("github", "", "o", "r", "main")).toBe(
        "https://github.com/o/r/tree/main",
      );
    });
  });
});
