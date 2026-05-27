import React from "react";
import { Text } from "@/components/text";
import { FloatingModal, ModalActions, ModalSection } from "@/components/modal";
import { Button } from "@/components/button";
import { Berlin } from "@/utils/fonts";
import { useForm } from "@/hooks/useForm";
import { Ok } from "@/services";
import { resetModule } from "@/services/modules";
import { Error } from "../page";
import styles from "./styles.module.css";

export const ResetModal = (props: { onRequestClose: () => void }) => {
  const form = useForm({}, async () => {
    const result = await resetModule();
    if (!result.ok) return result;
    window.location.reload();
    return Ok(null);
  });
  return (
    <FloatingModal onRequestClose={props.onRequestClose}>
      <form {...form.props}>
        <ModalSection>
          <Text type="h1">Reset Module Configuration</Text>
        </ModalSection>
        <ModalSection
          className={`${styles.mainModalSection} ${Berlin.className}`}
        >
          <p>
            <strong>Resetting</strong> the module configuration will remove all
            current module settings you have. To not lose your work, be sure to
            click on <strong>Create a Pull Request</strong> first.
          </p>
        </ModalSection>
        <ModalSection>
          {form.result && !form.result.ok && <Error {...form.result.error} />}
          <ModalActions align="right">
            <Button onClick={props.onRequestClose}>Cancel</Button>
            <Button style="warning" loading={form.loading} submit>
              Reset
            </Button>
          </ModalActions>
        </ModalSection>
      </form>
    </FloatingModal>
  );
};
