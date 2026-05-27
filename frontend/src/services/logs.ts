import { z } from "zod";
import { APIResult, fetchFromAPI } from ".";

const logLineSchema = z.object({
  timestamp: z.string().optional(),
  package: z.string().optional(),
  phase: z.string().optional(),
  log_message: z.string(),
});

const logPageSchema = z.object({
  finished: z.boolean(),
  max_page_size: z.number(),
  logs: z.array(logLineSchema),
});

export type LogPage = z.infer<typeof logPageSchema>;

export const getLogs = async (
  resourceType: "build" | "run",
  resourceId: string,
  after?: string,
): Promise<APIResult<LogPage>> => {
  return await fetchFromAPI(
    logPageSchema,
    "GET",
    `${resourceType}/${resourceId}/logs`,
    {
      query: after ? { after } : undefined,
    },
  );
};
