import { z } from "zod";
import { APIResult, Ok, fetchFromAPI } from ".";

export const getConfig = async (): Promise<
  APIResult<{ githubAppName: string; cacheUrl: string; giteaUrl: string }>
> => {
  const response = await fetchFromAPI(
    z.object({
      github_app_name: z.string(),
      cache_url: z.string(),
      gitea_url: z.string(),
    }),
    "GET",
    "config",
  );
  if (!response.ok) return response;
  return Ok({
    githubAppName: response.data.github_app_name,
    cacheUrl: response.data.cache_url,
    giteaUrl: response.data.gitea_url,
  });
};
