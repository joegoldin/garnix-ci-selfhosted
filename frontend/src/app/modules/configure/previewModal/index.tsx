import React from "react";
import { useRouter } from "next/navigation";
import { Text } from "@/components/text";
import { FloatingModal, ModalActions, ModalSection } from "@/components/modal";
import { Button } from "@/components/button";
import { Berlin } from "@/utils/fonts";
import { useForm } from "@/hooks/useForm";
import { Ok } from "@/services";
import { buildModule } from "@/services/modules";
import { Error } from "../page";
import styles from "./styles.module.css";

export const PreviewModal = (props: { onRequestClose: () => void }) => {
  const router = useRouter();
  const form = useForm({}, async () => {
    const buildResult = await buildModule();
    if (!buildResult.ok) return buildResult;
    router.push(`/commit/${buildResult.data.commit}`);
    return Ok(null);
  });
  return (
    <FloatingModal onRequestClose={props.onRequestClose}>
      <form {...form.props}>
        <ModalSection>
          <Text type="h1">Module Preview</Text>
        </ModalSection>
        <ModalSection
          className={`${styles.mainModalSection} ${Berlin.className}`}
        >
          <p>
            This will build your project, and deploy its servers if there are
            any. You will be redirected to our Builds page. Once you have
            checked the results, you can return to this page by clicking
            "Modules" on the left-hand navigation menu.
          </p>
        </ModalSection>
        <ModalSection>
          {form.result && !form.result.ok && <Error {...form.result.error} />}
          <ModalActions align="right">
            <Button onClick={props.onRequestClose}>Cancel</Button>
            <Button style="primaryInverse" loading={form.loading} submit>
              Continue
            </Button>
          </ModalActions>
        </ModalSection>
      </form>
    </FloatingModal>
  );
};
