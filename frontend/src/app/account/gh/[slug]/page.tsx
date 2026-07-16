"use client";
import Image from "next/image";
import React from "react";
import { Link } from "@/components/link";
import { Berlin } from "@/utils/fonts";
import { getOrgUsage } from "@/services/account";
import { fromMinutes, toMinutes } from "@/utils/duration";
import arrowLeft from "@/components/icons/arrow-left.svg";
import { useLoading } from "@/hooks/useLoading";
import { AppPage } from "@/utils/appPage";
import styles from "./styles.module.css";

// This self-host fork has no billing or plan limits, so this page just shows
// the org's raw usage for the current month.
const Page = ({ params }: { params: Record<string, string> }) => {
  const orgName = params.slug!;
  const usageLoading = useLoading(
    React.useCallback(() => getOrgUsage(orgName), [orgName]),
    { poll: fromMinutes(1) },
  );
  if (usageLoading.loading) return null;
  if (!usageLoading.data.ok)
    return <div>{usageLoading.data.error.message}</div>;
  const usage = usageLoading.data.data;

  return (
    <div className={styles.root}>
      <header>
        <Link
          className={styles.backButton}
          href="/account"
          title="Back to account overview"
        >
          <Image src={arrowLeft} alt="Back" />
        </Link>
        <h1>Account/{orgName}</h1>
      </header>
      <h2>Usage this month</h2>
      <div className={styles.threeUp}>
        <Stat name="CI Minutes" value={toMinutes(usage.ci_time).toFixed(1)} />
        <Stat
          name="PR Deployment Minutes"
          value={toMinutes(usage.pr_deployment_time).toFixed(1)}
        />
        <Stat
          name="Deployed Hosts"
          value={String(usage.branch_deployment_hosts)}
        />
      </div>
    </div>
  );
};

const Stat = (props: { name: string; value: string }) => (
  <div className={`${styles.usageMeter} ${styles.panel} ${Berlin.className}`}>
    <header>{props.name}</header>
    <div className={styles.values}>
      <strong>{props.value}</strong>
    </div>
  </div>
);

export default AppPage(Page, { requireAuth: true });
