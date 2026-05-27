import { z } from "zod";

export const formatZodError = (error: z.ZodError): string => {
  return error.issues
    .map((issue) => `In ${issue.path}: ${issue.message}`)
    .join("\n");
};
