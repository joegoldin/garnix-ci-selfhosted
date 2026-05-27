"use client";

import { PropsWithChildren } from "react";
import { Navigation } from "@/components/navigation";
import { AuthModalHeader } from "@/components/authModalHeader";
import { useUser } from "@/store/userContext";
import styles from "./styles.module.css";

export const WithSidebar = ({ children }: PropsWithChildren) => {
  const { user } = useUser();
  if (user.state === "logged-in") {
    return (
      <div className={styles.container}>
        <Navigation className={styles.navigation} />
        <div className={styles.children}>{children}</div>
      </div>
    );
  }
  return (
    <div className={styles.loggedOutContainer}>
      <AuthModalHeader type="signup" />
      <div className={styles.loggedOutContent}>{children}</div>
    </div>
  );
};
