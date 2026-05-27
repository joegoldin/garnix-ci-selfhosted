import React from "react";
import styles from "./styles.module.css";

export const FormSubmitResult = (props: {
  success?: boolean;
  children: React.ReactNode;
}) => {
  return (
    <div
      className={`${styles.root} ${props.success ? styles.success : styles.error}`}
    >
      {props.children}
    </div>
  );
};
