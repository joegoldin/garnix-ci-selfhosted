import { z } from "zod";
import {
  ConfirmPaymentData,
  Stripe,
  StripeElements,
  StripeElementsOptions,
} from "@stripe/stripe-js";
import stripe from "@stripe/stripe-js";
import { ConfirmationToken } from "@stripe/stripe-js";
import { fromSecs, toSecs } from "@/utils/duration";
import { mapCollectResult } from "@/utils";
import { APIResult, Err, Ok, Result, fetchFromAPI } from ".";

type Usage = {
  byOrg: Record<string, OrgUsage>;
};

export type Plan = z.infer<typeof planSchema>;
const planSchema = z.object({
  display_name: z.string(),
  description: z.optional(z.string()),
  base_ci_time: z.number().transform(fromSecs),
  maximum_pr_deployment_time: z.number().transform(fromSecs),
  included_branch_deployment_hosts: z.number(),
  extra_usage: z.object({
    ciTime: z.number().transform(fromSecs),
    prDeployTime: z.number().transform(fromSecs),
    hostingSpend: z.number().transform((cents) => Math.floor(cents / 100)),
  }),
  is_paid: z.boolean(),
});

export type UpgradeOption = z.infer<typeof upgradeOptionSchema>;
const upgradeOptionSchema = z.object({
  api_key: z.string(),
  product_token: z.string(),
  currency: z.string(),
  unit_amount: z.number(),
  plan: planSchema,
});

export type OrgUsage = z.infer<typeof orgUsageSchema>;
const orgUsageSchema = z.object({
  ci_time: z.number().transform(fromSecs),
  pr_deployment_time: z.number().transform(fromSecs),
  branch_deployment_hosts: z.number(),
  plan: planSchema,
  upgrade_option: z.optional(upgradeOptionSchema),
  installation_status: z.discriminatedUnion("tag", [
    z.object({ tag: z.literal("NoActiveInstallation") }),
    z.object({
      tag: z.literal("InstallationRenewing"),
      contents: z.coerce.date(),
    }),
    z.object({
      tag: z.literal("InstallationCancelling"),
      contents: z.coerce.date(),
    }),
  ]),
});
const usageResponseSchema = z.object({
  by_org: z.record(z.string(), orgUsageSchema),
});

export const getAccountUsage = async (): Promise<APIResult<Usage>> => {
  const res = await fetchFromAPI(usageResponseSchema, "GET", "account/usage");
  if (!res.ok) return res;
  return Ok({ byOrg: res.data.by_org });
};

export const getOrgUsage = (org: string): Promise<APIResult<OrgUsage>> => {
  return fetchFromAPI(orgUsageSchema, "GET", `account/usage/${org}`);
};

export const setUsageLimits = (
  org: string,
  newUsageLimits: Plan["extra_usage"],
): Promise<APIResult<unknown>> => {
  return fetchFromAPI(z.unknown(), "PUT", `account/usage/${org}`, {
    body: JSON.stringify({
      ciTime: toSecs(newUsageLimits.ciTime),
      prDeployTime: toSecs(newUsageLimits.prDeployTime),
      hostingSpend: newUsageLimits.hostingSpend * 100,
    }),
  });
};

export const getUpgradeOptionByToken = (
  product_token: string,
): Promise<APIResult<UpgradeOption>> => {
  return fetchFromAPI(
    upgradeOptionSchema,
    "GET",
    `account/upgrade_option?product_token=${product_token}`,
  );
};

export const mkStripeOptions = (
  appearance: stripe.Appearance,
  upgradeOption: UpgradeOption,
): StripeElementsOptions => ({
  appearance,
  mode: "subscription",
  currency: upgradeOption.currency,
  amount: upgradeOption.unit_amount,
});

const addressSchema = z.object({
  line1: z.string(),
  line2: z.string().nullable(),
  city: z.string(),
  state: z.string(),
  postal_code: z.string(),
  country: z.string(),
});
type Address = z.infer<typeof addressSchema>;

const taxCalculationSchema = z.object({
  object: z.literal("tax.calculation"),
  id: z.string(),
  currency: z.string(),
  amount_total: z.number(),
  tax_breakdown: z.array(
    z.object({
      amount: z.number(),
      tax_rate_details: z.object({
        tax_type: z.string().nullable(),
      }),
    }),
  ),
  customer_details: z.object({
    address: addressSchema,
  }),
});
export type TaxCalculation = z.infer<typeof taxCalculationSchema>;

export const getTaxCalculation = async ({
  unit_amount,
  currency,
  address,
}: {
  unit_amount: number;
  currency: string;
  address: Address;
}): Promise<APIResult<TaxCalculation>> =>
  fetchFromAPI(taxCalculationSchema, "POST", "account/taxes", {
    body: JSON.stringify({ unit_amount, currency, address }),
  });

export type SubmitPaymentInformationResult = {
  confirmationToken: ConfirmationToken;
  taxCalculation: TaxCalculation;
};

export const submitPaymentInformation = async ({
  stripe,
  elements,
  unit_amount,
  currency,
}: {
  stripe: Stripe;
  elements: StripeElements;
  unit_amount: number;
  currency: string;
}): Promise<Result<SubmitPaymentInformationResult>> => {
  const { error: submitError } = await elements.submit();
  if (submitError) {
    return Err({ message: submitError.message || submitError.type });
  }
  const address = (await elements.getElement("address")!.getValue()).value
    .address;
  const taxCalculationResult = await getTaxCalculation({
    unit_amount,
    currency,
    address,
  });
  if (!taxCalculationResult.ok) return taxCalculationResult;
  const confirmationTokenResult = await stripe.createConfirmationToken({
    elements,
  });
  if (confirmationTokenResult.error) {
    const error = confirmationTokenResult.error;
    return Err({
      message: error.message || error.type,
    });
  }
  return Ok({
    confirmationToken: confirmationTokenResult.confirmationToken,
    taxCalculation: taxCalculationResult.data,
  });
};

export const confirmPayment = async ({
  stripe,
  github_org,
  product_token,
  origin,
  confirmationToken,
}: {
  stripe: Stripe;
  github_org: string;
  product_token: string;
  origin: string;
  confirmationToken: ConfirmationToken;
}): Promise<Result<null>> => {
  const response = await fetchFromAPI(
    z.object({ client_secret: z.string() }),
    "POST",
    `account/subscribe`,
    { body: JSON.stringify({ github_org, product_token }) },
  );
  if (!response.ok) return Err({ message: response.error.message });
  const clientSecret = response.data.client_secret;
  const { error } = await stripe.confirmPayment({
    clientSecret,
    confirmParams: {
      return_url: `${origin}/account`,
      confirmation_token: confirmationToken.id,
    } as ConfirmPaymentData,
  });
  if (error) return Err({ message: error.message || error.type });
  return Ok(null);
};

export type AccountTokenScopes = z.infer<typeof accountTokenScopes>;
const accountTokenScopes = z.object({
  cache: z.boolean(),
  api: z.boolean(),
});

const accessTokenMetadata = z.object({
  id: z.number(),
  name: z.string(),
  created: z.coerce.date(),
  last_used: z.coerce.date().optional(),
  scopes: accountTokenScopes,
});

export const getAccessTokens = () => {
  return fetchFromAPI(
    z.object({ tokens: z.array(accessTokenMetadata) }),
    "GET",
    "account/tokens",
  );
};

type AccountTokensConfig = {
  name: string;
  scopes: AccountTokenScopes;
};

export const generateAccessToken = (body: AccountTokensConfig) => {
  return fetchFromAPI(
    z.object({ token: z.string() }),
    "POST",
    "account/tokens",
    { body: JSON.stringify(body) },
  );
};

export const revokeAccessToken = (tokenId: number) => {
  return fetchFromAPI(z.unknown(), "DELETE", `account/tokens/${tokenId}`);
};

export const getRepos = async () => {
  const result = await fetchFromAPI(
    z.object({ repos: z.array(z.string()) }),
    "GET",
    "account/repos",
  );
  if (!result.ok) return result;
  return mapCollectResult((repo) => {
    const [repoUser, repoName] = repo.split("/");
    if (!repoUser || !repoName) {
      return Err({ message: `Unable to parse repo: ${repo}` });
    }
    return Ok({ repoUser, repoName });
  }, result.data.repos);
};

export const cancelPlan = async (org: string) => {
  return await fetchFromAPI(
    z.unknown(),
    "DELETE",
    `account/subscription/${org}`,
    {},
  );
};
