import React from "react";
import { useRouter } from "next/navigation";
import { Text } from "@/components/text";
import { FloatingModal, ModalActions, ModalSection } from "@/components/modal";
import { Button } from "@/components/button";
import { Berlin } from "@/utils/fonts";
import { useForm } from "@/hooks/useForm";
import { Ok } from "@/services";
import { openPullRequest } from "@/services/modules";
import { Link } from "@/components/link";
import { Error } from "../page";
import styles from "./styles.module.css";

export const OpenPrModal = (props: { onRequestClose: () => void }) => {
  const router = useRouter();
  const form = useForm({}, async () => {
    const result = await openPullRequest();
    if (!result.ok) return result;
    router.push(result.data.url);
    return Ok(null);
  });
  return (
    <FloatingModal onRequestClose={props.onRequestClose}>
      <form {...form.props}>
        <ModalSection>
          <Text type="h1">Create a Pull Request</Text>
        </ModalSection>
        <ModalSection
          className={`${styles.mainModalSection} ${Berlin.className}`}
        >
          <p>
            This will create a pull request in your repository. Commits on top
            of those changes will trigger CI and deploy your servers. You can
            also use the code to run development shells or build locally
            (requires a local{" "}
            <Link className={styles.link} href="https://nixos.org/download/">
              nix
            </Link>{" "}
            installation).
          </p>
          <p>
            Once you have a pull request you are happy with, it is safe to reset
            this module configuration so you can use it for other repositories.
          </p>
        </ModalSection>
        <ModalSection>
          {form.result && !form.result.ok && <Error {...form.result.error} />}
          <ModalActions align="right">
            <Button onClick={props.onRequestClose}>Cancel</Button>
            <Button style="primaryInverse" loading={form.loading} submit>
              Create
            </Button>
          </ModalActions>
        </ModalSection>
      </form>
    </FloatingModal>
  );
};
