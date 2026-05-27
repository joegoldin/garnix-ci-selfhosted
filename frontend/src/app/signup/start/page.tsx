"use client";

import { useCallback, useState } from "react";
import { useRouter } from "next/navigation";
import { Text } from "@/components/text";
import { Modal, ModalActions, ModalSection } from "@/components/modal";
import { Button } from "@/components/button";
import { Link } from "@/components/link";
import { WithSidebar } from "@/components/withSidebar";
import { Berlin } from "@/utils/fonts";
import { useUser } from "@/store/userContext";
import { finishSignup } from "@/services/auth";
import styles from "./styles.module.css";

const Page = () => {
  const router = useRouter();
  const { user } = useUser();
  const [agreeTOS, setAgreeTOS] = useState(false);
  const [agreeEmail, setAgreeEmail] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const handleTOSChange = useCallback(() => {
    setAgreeTOS(!agreeTOS);
    if (!agreeTOS) setError(null);
  }, [agreeTOS, setAgreeTOS]);
  const handleEmailChange = useCallback(() => {
    setAgreeEmail(!agreeEmail);
  }, [agreeEmail, setAgreeEmail]);
  const submit = useCallback(async () => {
    if (user.state !== "logged-in" || !user.user.email)
      return setError("Something is wrong. Please logout and try again.");
    if (!agreeTOS)
      return setError("Please read and agree to the terms of service!");
    const path = await finishSignup(
      user.user.name,
      user.user.email,
      agreeEmail,
    );
    if (!path.ok) return setError(path.error.message);
    router.replace(path.data);
  }, [agreeTOS, agreeEmail, user, router]);
  const userOrNull = user.state === "logged-in" ? user.user : null;
  return (
    <WithSidebar>
      <div className={styles.container}>
        <Modal>
          <ModalSection className={styles.header}>
            <Text className={styles.h1} type="h1">
              Check and complete your information
            </Text>
          </ModalSection>
          <ModalSection className={styles.horizontalSection}>
            <label htmlFor="login">
              <Text className={styles.p} type="p">
                GitHub login
              </Text>
            </label>
            <input
              id="login"
              className={`${Berlin.className} ${styles.input}`}
              value={userOrNull?.name}
              readOnly
            />
          </ModalSection>
          <ModalSection className={styles.horizontalSection}>
            <label htmlFor="email">
              <Text className={styles.p} type="p">
                Email address
              </Text>
            </label>
            <input
              id="email"
              className={`${Berlin.className} ${styles.input}`}
              value={userOrNull?.email}
              readOnly
            />
          </ModalSection>
          <ModalSection>
            <div className={styles.checkboxContainer}>
              <input
                id="agreeTos"
                type="checkbox"
                checked={agreeTOS}
                onChange={handleTOSChange}
                className={styles.checkboxInput}
              />
              <label htmlFor="agreeTos">
                <Text className={styles.checkboxLabel} type="p">
                  I agree to{" "}
                  <Link
                    href="/signup/tos"
                    target="_blank"
                    className={styles.link}
                  >
                    Terms of Service
                  </Link>
                </Text>
              </label>
            </div>
            <div className={styles.checkboxContainer}>
              <input
                id="agreeEmail"
                type="checkbox"
                checked={agreeEmail}
                onChange={handleEmailChange}
                className={styles.checkboxInput}
              />
              <label htmlFor="agreeEmail">
                <Text className={styles.checkboxLabel} type="p">
                  I agree to receive emails about changes and new features
                </Text>
              </label>
            </div>
            {error && <Text className={styles.error}>{error}</Text>}
            <ModalActions>
              <Button onClick={submit} eventName="sign-up-complete">
                Submit
              </Button>
            </ModalActions>
          </ModalSection>
        </Modal>
      </div>
    </WithSidebar>
  );
};

export default Page;
