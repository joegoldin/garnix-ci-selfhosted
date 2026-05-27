import { Err, Ok } from "@/services";
import { mapCollectResult, sanitizeRedirectPath } from "./.";

describe("mapCollectResult", () => {
  it("collects into an Ok if all elements are Ok", () => {
    expect(mapCollectResult((e) => Ok(e + 1), [1, 2, 3])).toEqual(
      Ok([2, 3, 4]),
    );
  });

  it("collects into an Err if any element is an Err", () => {
    expect(
      mapCollectResult((e) => (e !== 3 ? Ok(e) : Err(e)), [1, 2, 3]),
    ).toEqual(Err(3));
  });

  it("collects into the first Err encountered, and stops the map", () => {
    expect(
      mapCollectResult(
        (e) => {
          if (e === 1) return Ok(1);
          if (e === 2) return Err("bad");
          throw Error("Should never run with e === 3");
        },
        [1, 2, 3],
      ),
    ).toEqual(Err("bad"));
  });

  it("collects empty lists into Ok([])", () => {
    expect(
      mapCollectResult(() => {
        throw Error("should not be called");
      }, []),
    ).toEqual(Ok([]));
  });
});

describe("sanitizeRedirectPath", () => {
  it("preserves valid paths", () => {
    expect(sanitizeRedirectPath("/valid/redirect/path")).toEqual(
      "/valid/redirect/path",
    );
  });

  describe("replaces invalid paths with /", () => {
    it.each([
      "some/relative/path",
      "https://example.org",
      "//example.org/some/path",
    ])("%s => /", (path) => {
      expect(sanitizeRedirectPath(path)).toEqual("/");
    });
  });
});
