"use client";
import { P, match } from "ts-pattern";
import {
  AddressElement,
  Elements,
  PaymentElement,
  useElements,
} from "@stripe/react-stripe-js";
import { Stripe, StripeElements, loadStripe } from "@stripe/stripe-js";
import { PropsWithChildren, ReactNode, useCallback } from "react";
import { useSearchParams } from "next/navigation";
import stripe from "@stripe/stripe-js";
import React from "react";
import { Text } from "@/components/text";
import { Err, Ok, Result } from "@/services";
import { useForm } from "@/hooks/useForm";
import {
  SubmitPaymentInformationResult,
  UpgradeOption,
  mkStripeOptions,
  submitPaymentInformation,
  confirmPayment,
  getUpgradeOptionByToken,
} from "@/services/account";
import { useLoading } from "@/hooks/useLoading";
import { Button } from "@/components/button";
import { Modal, ModalActions, ModalSection } from "@/components/modal";
import { formatPrice, formatTaxType } from "@/utils/currency";
import { trackSubmit } from "@/utils/analytics";
import { AppPage } from "@/utils/appPage";
import styles from "./styles.module.css";

const Page = () => {
  return (
    <React.Suspense fallback={null}>
      <div className={styles.container}>
        <Modal>
          <Billing />
        </Modal>
      </div>
    </React.Suspense>
  );
};

export default AppPage(Page, { requireAuth: true });

const Error = ({ children }: PropsWithChildren) => (
  <ModalSection>
    <Text className={styles.error}>{children}</Text>
  </ModalSection>
);

const Billing = (): ReactNode => {
  const params = useSearchParams();
  const product_token = params.get("product_token");
  const getUpgradeOption = React.useCallback(async (): Promise<
    Result<UpgradeOption>
  > => {
    if (!product_token) {
      return Err({ message: "Query param &apos;product_token&apos; not set!" });
    }
    return await getUpgradeOptionByToken(product_token);
  }, [product_token]);
  const loadingUpgradeOption = useLoading(getUpgradeOption);
  const account = params.get("account");
  if (!account) {
    return <Error>Query param &apos;account&apos; not set!</Error>;
  }
  if (loadingUpgradeOption.loading) return null;
  return match(loadingUpgradeOption.data)
    .with(Err(P.select()), (error) => {
      return (
        <Error>
          Sorry, there was an error!
          <div className={styles.errorSmall}>({error.message})</div>
        </Error>
      );
    })
    .with(Ok(P.select()), (upgrade_option) => {
      return <PaymentForm account={account} upgrade_option={upgrade_option} />;
    })
    .exhaustive();
};

const appearance: stripe.Appearance = {
  theme: "flat",
  variables: {
    colorPrimary: "#d6d3d1", // --color-stone-300
    colorBackground: "#ffffff", // --color-white
    colorText: "#57534e", // --color-stone-600
    borderRadius: "0",
    colorDanger: "red",
  },
  rules: {
    ".Input": {
      border: "2px solid #d6d3d1", // --color-stone-300
    },
  },
};

const PaymentForm = ({
  account,
  upgrade_option,
}: {
  account: string;
  upgrade_option: UpgradeOption;
}) => {
  const stripe = useLoading(
    useCallback(
      () => loadStripe(upgrade_option.api_key),
      [upgrade_option.api_key],
    ),
  );
  if (stripe.loading || stripe.data == null) return null;
  return (
    <Elements
      stripe={stripe.data}
      options={mkStripeOptions(appearance, upgrade_option)}
    >
      <PaymentFormHelper
        stripe={stripe.data}
        account={account}
        upgrade_option={upgrade_option}
      />
    </Elements>
  );
};

const PaymentFormHelper = ({
  stripe,
  account,
  upgrade_option,
}: {
  stripe: Stripe;
  account: string;
  upgrade_option: UpgradeOption;
}) => {
  const elements = useElements();
  const [submitResult, setSubmitResult] =
    React.useState<null | SubmitPaymentInformationResult>();
  if (elements == null) return null;
  return (
    <>
      <ModalSection>
        <Text className={styles.title} type="h1">
          {upgrade_option.plan.display_name}
        </Text>
        <Text className={styles.price}>
          {formatPrice(upgrade_option)} / month (without tax)
        </Text>
        <Text>{upgrade_option.plan.description}</Text>
      </ModalSection>
      <ModalSection>
        <Text className={styles.textWithPadding}>
          You&apos;re subscribing to the {upgrade_option.plan.display_name} for
          the GitHub account or organization <strong>{account}</strong>. This
          will allow you to use garnix&apos; services in the repos under that
          account or organization.
        </Text>
        <Text>
          Selected GitHub account or organization: <strong>{account}</strong>
        </Text>
      </ModalSection>
      {submitResult == null ? (
        <PaymentInformation
          stripe={stripe}
          elements={elements}
          upgrade_option={upgrade_option}
          onSubmit={setSubmitResult}
        />
      ) : (
        <PaymentConfirmation
          stripe={stripe}
          account={account}
          upgrade_option={upgrade_option}
          submitResult={submitResult}
        />
      )}
    </>
  );
};

const PaymentInformation = ({
  stripe,
  elements,
  upgrade_option,
  onSubmit,
}: {
  stripe: Stripe;
  elements: StripeElements;
  upgrade_option: UpgradeOption;
  onSubmit: (_: SubmitPaymentInformationResult) => void;
}) => {
  const form = useForm({}, async () => {
    trackSubmit("manage-plan-next");
    const submitResult = await submitPaymentInformation({
      stripe,
      elements,
      unit_amount: upgrade_option.unit_amount,
      currency: upgrade_option.currency,
    });
    if (!submitResult.ok) return submitResult;
    onSubmit(submitResult.data);
    return Ok(null);
  });
  const formJsx = (
    <form {...form.props}>
      <ModalSection>
        <Text type="h2">Payment Method</Text>
        <PaymentElement />
      </ModalSection>
      <ModalSection>
        <Text type="h2">Billing Address</Text>
        <AddressElement options={{ mode: "billing" }} />
      </ModalSection>
      <ModalSection>
        <ModalActions>
          <Button
            submit={true}
            loading={form.loading}
            eventName="billing-next-button"
          >
            Next
          </Button>
        </ModalActions>
      </ModalSection>
    </form>
  );
  return match(form.result)
    .with(
      Err({ type: "throw-in-on-submit", message: P.select() }),
      (message) => <Error>Something went wrong: {message} </Error>,
    )
    .with(Err({ message: P.select() }), (e) => (
      <>
        <Error>{e}</Error>
        {formJsx}
      </>
    ))
    .with(
      Ok(null),
      // This should switch to PaymentConfirmation
      () => null,
    )
    .with(null, () => formJsx)
    .exhaustive();
};

const PaymentConfirmation = ({
  stripe,
  account,
  upgrade_option,
  submitResult,
}: {
  stripe: Stripe;
  account: string;
  upgrade_option: UpgradeOption;
  submitResult: SubmitPaymentInformationResult;
}) => {
  const form = useForm({}, async (): Promise<Result<null>> => {
    trackSubmit("manage-plan-purchase-plan");
    return await confirmPayment({
      stripe,
      github_org: account,
      product_token: upgrade_option.product_token,
      origin: window.location.origin,
      confirmationToken: submitResult.confirmationToken,
    });
  });
  return match(form.result)
    .with(null, () => (
      <form {...form.props}>
        <ModalSection>
          <Text type="h2">Payment Summary</Text>
          <div className={styles.summaryContainer}>
            <table className={styles.summary}>
              <tbody>
                <tr>
                  <td>
                    <Text>Base Price:</Text>
                  </td>
                  <td>
                    <Text>{formatPrice(upgrade_option)}</Text>
                  </td>
                </tr>
                {submitResult.taxCalculation.tax_breakdown.map((item, i) => (
                  <tr key={i}>
                    <td>
                      <Text>
                        {formatTaxType(item.tax_rate_details.tax_type)}:
                      </Text>
                    </td>
                    <td>
                      <Text>
                        {formatPrice({
                          unit_amount: item.amount,
                          currency: submitResult.taxCalculation.currency,
                        })}
                      </Text>
                    </td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr>
                  <td>
                    <Text>Total (per month):</Text>
                  </td>
                  <td>
                    <Text>
                      {formatPrice({
                        unit_amount: submitResult.taxCalculation.amount_total,
                        currency: submitResult.taxCalculation.currency,
                      })}
                    </Text>
                  </td>
                </tr>
              </tfoot>
            </table>
          </div>
        </ModalSection>
        <ModalSection>
          <ModalActions>
            <Button submit={true}>Purchase Plan</Button>
          </ModalActions>
        </ModalSection>
      </form>
    ))
    .with(
      Ok(null),
      // In this case there should be a redirect (via stripe) to `/account`
      () => null,
    )
    .with(
      Err({ type: "throw-in-on-submit", message: P.select() }),
      (message) => <Error>Something went wrong: {message}</Error>,
    )
    .with(Err({ message: P.select() }), (message) => <Error>{message}</Error>)
    .exhaustive();
};
