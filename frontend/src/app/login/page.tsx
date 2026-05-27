"use client";

import { redirect } from "next/navigation";
import { useCallback } from "react";
import { Text } from "@/components/text";
import { getLoginLink } from "@/services/auth";
import { useLoading } from "@/hooks/useLoading";
import styles from "./styles.module.css";

type PageProps = {
  searchParams: Record<string, string>;
};

const Page = (props: PageProps) => {
  const loginLink = useLoading(
    useCallback(
      () => getLoginLink(props.searchParams.page || null),
      [props.searchParams.page],
    ),
  );
  if (loginLink.loading) return null;
  if (!loginLink.data.ok) {
    return (
      <Text className={styles.error}>
        Error on login: {loginLink.data.error.message}
      </Text>
    );
  }
  return redirect(loginLink.data.data);
};

export default Page;
