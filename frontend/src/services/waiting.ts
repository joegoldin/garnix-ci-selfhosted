import { z } from "zod";

export type WaitNode = {
  id: string;
  kind: string;
  label: string;
  detail: string | null;
  href: string | null;
  startedAt: Date | null;
  lastActivityAt: Date | null;
  children: WaitNode[];
};

type WaitNodeInput = {
  id: string;
  kind: string;
  label: string;
  detail?: string | null;
  href?: string | null;
  started_at?: Date | null;
  last_activity_at?: Date | null;
  children: WaitNodeInput[];
};

export const waitNodeSchema: z.ZodType<
  WaitNode,
  z.ZodTypeDef,
  WaitNodeInput
> = z.lazy(() =>
  z
    .object({
      id: z.string(),
      kind: z.string(),
      label: z.string(),
      detail: z.string().nullish(),
      href: z.string().nullish(),
      started_at: z.coerce.date().nullish(),
      last_activity_at: z.coerce.date().nullish(),
      children: z.array(waitNodeSchema),
    })
    .transform((node) => ({
      id: node.id,
      kind: node.kind,
      label: node.label,
      detail: node.detail ?? null,
      href: node.href ?? null,
      startedAt: node.started_at ?? null,
      lastActivityAt: node.last_activity_at ?? null,
      children: node.children,
    })),
);
