import { z } from "zod";
import { APIResult, Ok, fetchFromAPI } from ".";

export const getConfig = async (): Promise<
  APIResult<{
    githubAppName: string;
    cacheUrl: string;
    giteaUrl: string;
    selfHostMode: boolean;
    sshHost: string;
    hostingPublicIp: string | null;
    hostingDomain: string;
    hostingBases: string[];
  }>
> => {
  const response = await fetchFromAPI(
    z.object({
      github_app_name: z.string(),
      cache_url: z.string(),
      gitea_url: z.string(),
      // Tolerate an older backend that predates the flag: default to false.
      self_host_mode: z
        .boolean()
        .optional()
        .transform((v) => v ?? false),
      // External ssh host for deployed-server DNAT ports; "" / absent when unset.
      ssh_host: z
        .string()
        .optional()
        .transform((v) => v ?? ""),
      // Public IP of the garnix host, for A-record instructions in the Servers
      // (i) DNS-help modal; null/absent when unset (CNAME instructions instead).
      hosting_public_ip: z
        .string()
        .nullable()
        .optional()
        .transform((v) => v ?? null),
      // Default hosting base domain (the CNAME target for bare custom domains).
      hosting_domain: z
        .string()
        .optional()
        .transform((v) => v ?? ""),
      // All base domains under which a subdomain is wildcard-covered (default +
      // operator extras + verified connected domains).
      hosting_bases: z
        .array(z.string())
        .optional()
        .transform((v) => v ?? []),
    }),
    "GET",
    "config",
  );
  if (!response.ok) return response;
  return Ok({
    githubAppName: response.data.github_app_name,
    cacheUrl: response.data.cache_url,
    giteaUrl: response.data.gitea_url,
    selfHostMode: response.data.self_host_mode,
    sshHost: response.data.ssh_host,
    hostingPublicIp: response.data.hosting_public_ip,
    hostingDomain: response.data.hosting_domain,
    hostingBases: response.data.hosting_bases,
  });
};
