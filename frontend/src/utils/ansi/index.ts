import { CSSProperties } from "react";
import { colors } from "./colors";

const baseStyle = {
  bold: false,
  dim: false,
  italic: false,
  underline: false,
  inverse: false,
  strikethrough: false,
  fg: "#000",
  bg: "transparent",
};

type Style = typeof baseStyle;

export type StyledText = Array<[CSSProperties, string]>;

export function styleLines(lines: Array<string>): Array<StyledText> {
  const { styled } = lines.reduce(
    (acc: { next: Style; styled: Array<StyledText> }, line) => {
      const { next, styled } = styleLine(line, acc.next);
      return { next, styled: [...acc.styled, styled] };
    },
    { next: baseStyle, styled: [] },
  );
  return styled;
}

/**
 * Style ANSI sequences are of the form `<ESC>[<CODES>m` where <ESC> is the
 * escape character (\x1b) and <CODES> is a semicolon separated list of codes
 * in decimal, e.g. `\x1b[23;42;51m`.
 *
 * STYLE_ESCAPE_REGEXP matches this sequence, except for the escape character.
 */
const STYLE_ESCAPE_REGEXP = /^\[([0-9;]*)m(.*)/;

function styleLine(
  text: string,
  prevLineStyle: Style,
): { next: Style; styled: StyledText } {
  const escapePoints = text.split("\x1b");
  let curStyle = prevLineStyle;
  const parts: Array<[CSSProperties, string]> = [];
  const firstPart = escapePoints.shift()!;
  if (firstPart.length > 0) parts.push([styleToCss(curStyle), firstPart]);
  for (const escapePoint of escapePoints) {
    const match = escapePoint.match(STYLE_ESCAPE_REGEXP);
    if (!match) {
      parts.push([styleToCss(curStyle), escapePoint]);
      continue;
    }
    const [_, codesStr, text] = match as [string, string, string];
    const codes =
      codesStr === ""
        ? [0]
        : codesStr.split(";").map((code) => parseInt(code, 10));
    while (codes.length > 0) curStyle = handleNextCode(curStyle, codes);
    parts.push([styleToCss(curStyle), text]);
  }
  return { next: curStyle, styled: parts };
}

function handleNextCode(cur: Style, codes: Array<number>): Style {
  const code = codes.shift();
  // prettier-ignore
  switch (code) {
    case 0: return baseStyle;
    case 1: return { ...cur, bold: true };
    case 2: return { ...cur, dim: true };
    case 3: return { ...cur, italic: true };
    case 4: return { ...cur, underline: true };
    case 7: return { ...cur, inverse: true };
    case 9: return { ...cur, strikethrough: true };
    case 21: return { ...cur, bold: false };
    case 22: return { ...cur, bold: false, dim: false };
    case 23: return { ...cur, italic: false };
    case 24: return { ...cur, underline: false };
    case 27: return { ...cur, inverse: false };
    case 29: return { ...cur, strikethrough: false };
    case 39: return { ...cur, fg: baseStyle.fg };
    case 49: return { ...cur, bg: baseStyle.bg };
    case 30: case 31: case 32: case 33: case 34: case 35: case 36: case 37:
      return { ...cur, fg: colors[code - 30]! };
    case 40: case 41: case 42: case 43: case 44: case 45: case 46: case 47:
      return { ...cur, bg: colors[code - 40]! };
    case 38: case 48: {
      // set the foreground (if the code is 38)
      // or set the background (if the code is 48)
      // to either a specific RGB value (if the next code is 2)
      // or 256-color (if the next code is 5)
      const key = code === 38 ? 'fg' : 'bg';
      if (codes[0] === 2) {
        codes.shift(); // discard "2"
        const [r, g, b] = [codes.shift(), codes.shift(), codes.shift()];
        return { ...cur, [key]: `rgb(${r},${g},${b})` };
      } else if (codes[0] === 5) {
        codes.shift(); // discard "5"
        const colorIdx = codes.shift();
        if (colorIdx != null) return { ...cur, [key]: colors[colorIdx] };
      }
      break;
    }
  }
  return cur;
}

function styleToCss(s: Style): CSSProperties {
  const css: CSSProperties = {};
  if (s.bold) css.fontWeight = "bold";
  if (s.dim) css.opacity = 0.8;
  if (s.italic) css.fontStyle = "italic";
  if (s.underline) css.textDecoration = "underline";
  if (s.strikethrough)
    css.textDecoration = [css.textDecoration, "line-through"]
      .filter((s) => s)
      .join(" ");
  const fg = s.inverse ? s.bg : s.fg;
  const bg = s.inverse ? s.fg : s.bg;
  if (fg !== baseStyle.fg) css.color = fg;
  if (bg !== baseStyle.bg) css.background = bg;
  return css;
}
