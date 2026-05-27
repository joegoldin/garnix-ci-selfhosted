import nextJest from "next/jest.js";

const createJestConfig = nextJest({
  dir: "./",
});

export default createJestConfig({
  testEnvironment: "jsdom",
  // Needed to make `toMatchInlineSnapshot` work,
  // see https://jestjs.io/docs/configuration/#prettierpath-string
  prettierPath: null,
  setupFiles: ["jest-canvas-mock"],
  moduleNameMapper: {
    "\\.wasm$": "<rootDir>/jest-wasm-mock.js",
  },
});
