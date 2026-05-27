"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { Text } from "@/components/text";
import { Modal, ModalActions, ModalSection } from "@/components/modal";
import { GithubIcon } from "@/components/icons/github";
import { AuthModalHeader } from "@/components/authModalHeader";
import { Button } from "@/components/button";
import { useUser } from "@/store/userContext";
import { setLoginTargetPage } from "@/services/auth";
import { sanitizeRedirectPath } from "@/utils";
import styles from "./styles.module.css";

const Page = (props: { searchParams: Record<string, string> }) => {
  const { user, signupLink } = useUser();
  const router = useRouter();
  const search = useSearchParams();
  if (user.state === "logged-in") {
    router.replace(sanitizeRedirectPath(search.get("path") ?? "/"));
    return null;
  }
  return (
    <main className={styles.container}>
      <Modal>
        <AuthModalHeader type="signup" />
        <ModalSection className={styles.steps}>
          <Text className={styles.h1} type="h1">
            Getting started with garnix is easy.
          </Text>
          <div className={styles.step}>
            <div className={styles.number}>1</div>
            <Text>
              As a first step, you&apos;ll be taken to github to install the
              garnix app. Here you can pick which repositories to run garnix on.
            </Text>
          </div>
          <div className={styles.step}>
            <div className={styles.number}>2</div>
            <Text>
              You&apos;ll also be asked to confirm that you allow us to see your
              email and github login. We use that to log you in.
            </Text>
          </div>
          <div className={styles.step}>
            <div className={styles.number}>3</div>
            <Text>
              When that&apos;s finished, you&apos;ll be brought back here to
              complete the signup process.
            </Text>
          </div>
          <ModalActions>
            {signupLink && (
              <Button
                onClick={() => {
                  setLoginTargetPage(props.searchParams.page || null);
                  router.replace(signupLink);
                }}
                eventName="sign-up-with"
              >
                <GithubIcon className={styles.icon} /> Sign up with GitHub
              </Button>
            )}
          </ModalActions>
        </ModalSection>
      </Modal>
    </main>
  );
};

export default Page;
