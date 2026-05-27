// @lintignore
export const dbg = <T,>(t: T, message?: string): T => {
  const string = JSON.stringify(t, null, 2);
  if (typeof string === "undefined") {
    console.log(message, t);
  } else {
    console.log(`${message || "dbg"}: ${string}`);
  }
  return t;
};
