"use client";

import React from "react";
import { Button } from "@/components/button";
import { FloatingModal, ModalActions, ModalSection } from "@/components/modal";
import { Text } from "@/components/text";

export const ConfirmActionButton = ({
  triggerLabel,
  title,
  description,
  confirmLabel,
  onConfirm,
}: {
  triggerLabel: string;
  title: string;
  description: React.ReactNode;
  confirmLabel: string;
  onConfirm: () => Promise<void>;
}) => {
  const [open, setOpen] = React.useState(false);
  const [busy, setBusy] = React.useState(false);

  const confirm = async () => {
    setBusy(true);
    try {
      await onConfirm();
      setOpen(false);
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <Button style="warning" onClick={() => setOpen(true)}>
        {triggerLabel}
      </Button>
      {open ? (
        <FloatingModal onRequestClose={() => !busy && setOpen(false)}>
          <ModalSection>
            <Text type="h1">{title}</Text>
          </ModalSection>
          <ModalSection>{description}</ModalSection>
          <ModalSection>
            <ModalActions align="right">
              <Button onClick={() => setOpen(false)} loading={busy}>
                Keep running
              </Button>
              <Button style="warning" loading={busy} onClick={confirm}>
                {confirmLabel}
              </Button>
            </ModalActions>
          </ModalSection>
        </FloatingModal>
      ) : null}
    </>
  );
};
