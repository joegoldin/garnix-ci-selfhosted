import { PropsWithChildren } from "react";
import { Portal } from "@/components/portal";
import styles from "./styles.module.css";

export const FloatingModal = (props: {
  children: React.ReactNode;
  className?: string;
  onRequestClose: () => void;
}) => {
  return (
    <>
      <Portal>
        <Modal className={`${styles.floating} ${props.className}`}>
          {props.children}
        </Modal>
        <div className={styles.backdrop} onClick={props.onRequestClose} />
      </Portal>
    </>
  );
};

export const Modal = ({
  children,
  className,
}: PropsWithChildren<{ className?: string }>) => {
  return (
    <div className={`${styles.container} ${className}`}>
      <div className={styles.body}>{children}</div>
    </div>
  );
};

type ModalSectionProps = PropsWithChildren & {
  className?: string;
};

export const ModalSection = ({ children, className }: ModalSectionProps) => {
  return (
    <section className={`${styles.section} ${className}`}>{children}</section>
  );
};

export const ModalActions = ({
  align,
  children,
}: PropsWithChildren<{ align?: "left" | "right" }>) => {
  return (
    <div
      className={styles.actions}
      style={{ justifyContent: align === "right" ? "flex-end" : undefined }}
    >
      {children}
    </div>
  );
};
