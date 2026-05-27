import { Err, Ok } from "@/services";
import { NixValue } from "./nixValue";
import { ModuleSchema, peelOffToplevel, validate, wrapInToplevel } from ".";

const testSchema: ModuleSchema = {
  typ: {
    tag: "submodule",
    fields: {
      testStack: {
        typ: {
          tag: "attrsOf",
          fieldType: { tag: "submodule", fields: {} },
        },
      },
    },
  },
};

const testValue: NixValue = {
  tag: "set",
  value: {
    testStack: {
      tag: "set",
      value: { "testStack-project": { tag: "set", value: {} } },
    },
  },
};

const testCommit: string = "aaaa";

describe("peelOffToplevel", () => {
  it("peels of a `submodule` and an `attrsOf`", () => {
    const result = peelOffToplevel(testSchema, testValue, testCommit);
    expect(result).toMatchInlineSnapshot(`
      {
        "data": {
          "gitCommit": "aaaa",
          "initialValue": {
            "tag": "set",
            "value": {},
          },
          "moduleSchema": {
            "fields": {},
            "tag": "submodule",
          },
          "projectName": "testStack-project",
          "stackName": "testStack",
        },
        "ok": true,
      }
    `);
  });
});

describe("wrapInToplevel", () => {
  it("adds the peeled off toplevels back on", () => {
    const result = peelOffToplevel(testSchema, testValue, testCommit);
    if (!result.ok) throw result.error;
    const withoutToplevel = result.data;
    const withToplevel = wrapInToplevel({
      stackName: withoutToplevel.stackName,
      projectName: withoutToplevel.projectName,
      value: withoutToplevel.initialValue,
    });
    expect(withToplevel).toEqual(testValue);
  });
});

describe("validate", () => {
  it("returns Ok if there are no validation errors", () => {
    const result = validate({
      moduleSchema: {
        tag: "submodule",
        fields: {
          bool: { typ: { tag: "bool" } },
          path: { typ: { tag: "path" } },
          str: { typ: { tag: "str" } },
          package: { typ: { tag: "package" } },
        },
      },
      moduleValue: {
        tag: "set",
        value: {
          bool: { tag: "bool", value: true },
          path: { tag: "path", value: "./." },
          str: { tag: "string", value: "foo" },
          package: { tag: "raw", value: "pkgs.foo" },
        },
      },
    });
    expect(result).toEqual(Ok(null));
  });

  it("allows empty values for types.str", () => {
    const result = validate({
      moduleSchema: {
        tag: "submodule",
        fields: {
          foo: { typ: { tag: "str" } },
        },
      },
      moduleValue: {
        tag: "set",
        value: {
          foo: { tag: "string", value: "" },
        },
      },
    });
    expect(result).toEqual(Ok(null));
  });

  it("errors on empty strings for types.nonEmptyStr", () => {
    const result = validate({
      moduleSchema: {
        tag: "submodule",
        fields: {
          foo: { typ: { tag: "nonEmptyStr" } },
        },
      },
      moduleValue: {
        tag: "set",
        value: {
          foo: { tag: "string", value: "" },
        },
      },
    });
    expect(result).toEqual(
      Err({
        message: "Field cannot be empty.",
        path: ["foo"],
      }),
    );
  });

  it("errors on paths that contain spaces", () => {
    const result = validate({
      moduleSchema: {
        tag: "submodule",
        fields: {
          foo: { typ: { tag: "path" } },
        },
      },
      moduleValue: {
        tag: "set",
        value: {
          foo: { tag: "path", value: "./this is not valid" },
        },
      },
    });
    expect(result).toEqual(
      Err({
        message: "Path cannot contain illegal characters.",
        path: ["foo"],
      }),
    );
  });

  it("allows `null` for `nullOr` schemas", () => {
    const result = validate({
      moduleSchema: {
        innerType: { tag: "str" },
        tag: "nullOr",
      },
      moduleValue: { tag: "null" },
    });
    expect(result).toEqual(Ok(null));
  });

  it("disallows `null` for non-nullable schemas", () => {
    const result = validate({
      moduleSchema: { tag: "str" },
      moduleValue: { tag: "null" },
    });
    expect(result).toEqual(
      Err({
        message:
          "Value does not match schema: expected type: str, got: null of type null",
        path: [],
      }),
    );
  });

  it("allows `null` for `nullOr` of `submodule`", () => {
    const result = validate({
      moduleSchema: {
        innerType: {
          fields: {
            foo: { typ: { tag: "str" } },
          },
          tag: "submodule",
        },
        tag: "nullOr",
      },
      moduleValue: { tag: "null" },
    });
    expect(result).toEqual(Ok(null));
  });

  it("errors on negative unsignedInt16s", () => {
    const result = validate({
      moduleSchema: {
        tag: "submodule",
        fields: {
          foo: { typ: { tag: "unsignedInt16" } },
        },
      },
      moduleValue: {
        tag: "set",
        value: {
          foo: { tag: "int", value: -1 },
        },
      },
    });
    expect(result).toEqual(
      Err({
        message: "value must be positive",
        path: ["foo"],
      }),
    );
  });

  it("errors on unsignedInt16s above 65535", () => {
    const result = validate({
      moduleSchema: {
        tag: "submodule",
        fields: {
          foo: { typ: { tag: "unsignedInt16" } },
        },
      },
      moduleValue: {
        tag: "set",
        value: {
          foo: { tag: "int", value: 65536 },
        },
      },
    });
    expect(result).toEqual(
      Err({
        message: "value must be below 65536",
        path: ["foo"],
      }),
    );
  });

  it("allows unsignedInt16s in range", () => {
    const result = validate({
      moduleSchema: {
        tag: "submodule",
        fields: {
          foo: { typ: { tag: "unsignedInt16" } },
          bar: { typ: { tag: "unsignedInt16" } },
        },
      },
      moduleValue: {
        tag: "set",
        value: {
          foo: { tag: "int", value: 1 },
          bar: { tag: "int", value: 65535 },
        },
      },
    });
    expect(result).toEqual(Ok(null));
  });
});
