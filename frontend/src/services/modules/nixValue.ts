import { z } from "zod";

export type Repo = {
  repoUser: string;
  repoName: string;
};

export type EncryptedSecret = {
  encryptedFor: Repo;
  encryptedValue: string;
};

const encryptedSecretSchema: z.ZodType<EncryptedSecret> = z.object({
  encryptedFor: z.object({
    repoUser: z.string(),
    repoName: z.string(),
  }),
  encryptedValue: z.string(),
});

export type NixValue =
  | { tag: "encryptedSecret"; value: EncryptedSecret | null }
  | { tag: "string"; value: string }
  | { tag: "path"; value: string }
  | { tag: "raw"; value: string }
  | { tag: "bool"; value: boolean }
  | { tag: "int"; value: number }
  | { tag: "null" }
  | { tag: "set"; value: Record<string, NixValue> }
  | { tag: "list"; value: Array<NixValue> };

export const nixValueSchema: z.ZodType<NixValue> = z.discriminatedUnion("tag", [
  z.object({ tag: z.literal("encryptedSecret"), value: encryptedSecretSchema }),
  z.object({ tag: z.literal("string"), value: z.string() }),
  z.object({ tag: z.literal("path"), value: z.string() }),
  z.object({ tag: z.literal("raw"), value: z.string() }),
  z.object({ tag: z.literal("bool"), value: z.boolean() }),
  z.object({ tag: z.literal("int"), value: z.number() }),
  z.object({ tag: z.literal("null") }),
  z.object({
    tag: z.literal("set"),
    value: z.record(
      z.string(),
      z.lazy(() => nixValueSchema),
    ),
  }),
  z.object({
    tag: z.literal("list"),
    value: z.array(z.lazy(() => nixValueSchema)),
  }),
]);
