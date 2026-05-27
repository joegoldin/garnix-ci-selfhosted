import { CSSProperties } from "react";
import { colors } from "./colors";
import { styleLines } from "./";

describe("ANSI", () => {
  it("Leaves unstyled text alone", () => {
    expect(styleLines(["Hello world"])).toEqual([[[{}, "Hello world"]]]);
  });

  it("Ignores non-style related ANSI sequences", () => {
    // We basically end up losing the escape byte but retain the sequence,
    // which may seem weird, but the escape character doesn't render in the
    // browser anyway and it adds unnecessary complexity for now to either
    // preserve the escape character or detect and completely strip out the
    // entire sequence.
    expect(styleLines(["Hello\x1bworld"])).toEqual([
      [
        [{}, "Hello"],
        [{}, "world"],
      ],
    ]);
  });

  describe("basic styling", () => {
    it("allows setting and unsetting bold text", () => {
      // Both 21 and 22 reset bold
      for (const resetCode of [21, 22]) {
        expect(
          styleLines([`normal${ansi(1)}bold${ansi(resetCode)}back to normal`]),
        ).toEqual([
          [
            [{}, "normal"],
            [bold, "bold"],
            [{}, "back to normal"],
          ],
        ]);
      }
    });

    it("allows setting and unsetting dim text", () => {
      expect(
        styleLines([`normal${ansi(2)}dim${ansi(22)}back to normal`]),
      ).toEqual([
        [
          [{}, "normal"],
          [dim, "dim"],
          [{}, "back to normal"],
        ],
      ]);
    });

    it("allows setting and unsetting italic text", () => {
      expect(
        styleLines([`normal${ansi(3)}italic${ansi(23)}back to normal`]),
      ).toEqual([
        [
          [{}, "normal"],
          [italic, "italic"],
          [{}, "back to normal"],
        ],
      ]);
    });

    it("allows setting and unsetting underline text", () => {
      expect(
        styleLines([`normal${ansi(4)}underline${ansi(24)}back to normal`]),
      ).toEqual([
        [
          [{}, "normal"],
          [underline, "underline"],
          [{}, "back to normal"],
        ],
      ]);
    });

    it("allows setting and unsetting strikethrough text", () => {
      expect(
        styleLines([`normal${ansi(9)}strikethrough${ansi(29)}back to normal`]),
      ).toEqual([
        [
          [{}, "normal"],
          [strikethrough, "strikethrough"],
          [{}, "back to normal"],
        ],
      ]);
    });

    it("resets styling with 0 code", () => {
      expect(
        styleLines([`${ansi(1, 3)}bold & italic${ansi(0)}back to normal`]),
      ).toEqual([
        [
          [{ ...bold, ...italic }, "bold & italic"],
          [{}, "back to normal"],
        ],
      ]);
    });

    it("resets styling with an empty code", () => {
      expect(
        styleLines([`${ansi(1, 3)}bold & italic${ansi()}back to normal`]),
      ).toEqual([
        [
          [{ ...bold, ...italic }, "bold & italic"],
          [{}, "back to normal"],
        ],
      ]);
    });
  });

  describe("complex interactions", () => {
    it("handles adding and removing multiple styles on a single line", () => {
      expect(
        styleLines([
          `${ansi(1)}bold${ansi(2)}bold and dim${ansi(
            3,
          )}bold, dim and italic${ansi(21)}dim and italic${ansi(23)}just dim`,
        ]),
      ).toEqual([
        [
          [bold, "bold"],
          [{ ...bold, ...dim }, "bold and dim"],
          [{ ...bold, ...dim, ...italic }, "bold, dim and italic"],
          [{ ...dim, ...italic }, "dim and italic"],
          [dim, "just dim"],
        ],
      ]);
    });

    it("allows passing style state through from previous lines", () => {
      expect(
        styleLines([
          `${ansi(1)}bold${ansi(3)}italic`,
          "bold & italic from previous line",
        ]),
      ).toEqual([
        [
          [bold, "bold"],
          [{ ...bold, ...italic }, "italic"],
        ],
        [[{ ...bold, ...italic }, "bold & italic from previous line"]],
      ]);
    });
  });

  describe("colors", () => {
    it("allows setting basic foreground colors", () => {
      for (let i = 0; i < 8; i++) {
        expect(
          styleLines([
            `normal${ansi(30 + i)}color${i}${ansi(0)}back to normal`,
          ]),
        ).toEqual([
          [
            [{}, "normal"],
            [{ color: colors[i] }, `color${i}`],
            [{}, "back to normal"],
          ],
        ]);
      }
    });

    it("allows setting basic background colors", () => {
      for (let i = 0; i < 8; i++) {
        expect(
          styleLines([
            `normal${ansi(40 + i)}color${i}${ansi(0)}back to normal`,
          ]),
        ).toEqual([
          [
            [{}, "normal"],
            [{ background: colors[i] }, `color${i}`],
            [{}, "back to normal"],
          ],
        ]);
      }
    });

    it("allows setting 8-bit foreground colors", () => {
      for (let i = 0; i < 256; i++) {
        expect(
          styleLines([
            `normal${ansi(38, 5, i)}color${i}${ansi(0)}back to normal`,
          ]),
        ).toEqual([
          [
            [{}, "normal"],
            [{ color: colors[i] }, `color${i}`],
            [{}, "back to normal"],
          ],
        ]);
      }
    });

    it("allows setting 8-bit background colors", () => {
      for (let i = 0; i < 256; i++) {
        expect(
          styleLines([
            `normal${ansi(48, 5, i)}color${i}${ansi(0)}back to normal`,
          ]),
        ).toEqual([
          [
            [{}, "normal"],
            [{ background: colors[i] }, `color${i}`],
            [{}, "back to normal"],
          ],
        ]);
      }
    });

    it("allows setting 24-bit foreground colors", () => {
      expect(
        styleLines([
          `normal${ansi(38, 2, 42, 43, 44)}color${ansi(0)}back to normal`,
        ]),
      ).toEqual([
        [
          [{}, "normal"],
          [{ color: "rgb(42,43,44)" }, "color"],
          [{}, "back to normal"],
        ],
      ]);
    });

    it("allows setting 24-bit background colors", () => {
      expect(
        styleLines([
          `normal${ansi(48, 2, 42, 43, 44)}color${ansi(0)}back to normal`,
        ]),
      ).toEqual([
        [
          [{}, "normal"],
          [{ background: "rgb(42,43,44)" }, "color"],
          [{}, "back to normal"],
        ],
      ]);
    });

    it("allows resetting foreground", () => {
      expect(styleLines([`${ansi(32)}green${ansi(39)}back to normal`])).toEqual(
        [
          [
            [{ color: colors[2] }, "green"],
            [{}, "back to normal"],
          ],
        ],
      );
    });

    it("allows resetting background", () => {
      expect(styleLines([`${ansi(42)}green${ansi(49)}back to normal`])).toEqual(
        [
          [
            [{ background: colors[2] }, "green"],
            [{}, "back to normal"],
          ],
        ],
      );
    });

    describe("inverting", () => {
      it("allows inverting without setting any colors", () => {
        expect(
          styleLines([`normal${ansi(7)}inverted${ansi(27)}back to normal`]),
        ).toEqual([
          [
            [{}, "normal"],
            [{ color: "transparent", background: "#000" }, "inverted"],
            [{}, "back to normal"],
          ],
        ]);
      });

      it("inverts basic colors", () => {
        expect(
          styleLines([
            `${ansi(32, 44)}green on blue${ansi(7)}blue on green${ansi(
              33,
            )}blue on yellow`,
          ]),
        ).toEqual([
          [
            [{ color: colors[2], background: colors[4] }, "green on blue"],
            [{ color: colors[4], background: colors[2] }, "blue on green"],
            [{ color: colors[4], background: colors[3] }, "blue on yellow"],
          ],
        ]);
      });

      it("inverts 8-bit colors", () => {
        expect(
          styleLines([
            `${ansi(38, 5, 2, 48, 5, 4)}green on blue${ansi(
              7,
            )}blue on green${ansi(38, 5, 3)}blue on yellow`,
          ]),
        ).toEqual([
          [
            [{ color: colors[2], background: colors[4] }, "green on blue"],
            [{ color: colors[4], background: colors[2] }, "blue on green"],
            [{ color: colors[4], background: colors[3] }, "blue on yellow"],
          ],
        ]);
      });

      it("inverts 24-bit colors", () => {
        expect(
          styleLines([
            `${ansi(38, 2, 0, 255, 0, 48, 2, 0, 0, 255)}green on blue${ansi(
              7,
            )}blue on green${ansi(38, 2, 255, 255, 0)}blue on yellow`,
          ]),
        ).toEqual([
          [
            [
              { color: "rgb(0,255,0)", background: "rgb(0,0,255)" },
              "green on blue",
            ],
            [
              { color: "rgb(0,0,255)", background: "rgb(0,255,0)" },
              "blue on green",
            ],
            [
              { color: "rgb(0,0,255)", background: "rgb(255,255,0)" },
              "blue on yellow",
            ],
          ],
        ]);
      });
    });
  });
});

// Test helpers
const ansi = (...code: Array<number>) => `\x1b[${code.join(";")}m`;
const bold: CSSProperties = { fontWeight: "bold" };
const dim: CSSProperties = { opacity: 0.8 };
const italic: CSSProperties = { fontStyle: "italic" };
const underline: CSSProperties = { textDecoration: "underline" };
const strikethrough: CSSProperties = { textDecoration: "line-through" };
