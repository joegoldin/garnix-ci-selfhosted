import Image from "next/image";
import successIcon from "@/components/icons/success.svg";
import failureIcon from "@/components/icons/failure.svg";
import pendingIcon from "@/components/icons/pending.svg";
import skippedIcon from "@/components/icons/dash.svg";
import { BuildStatus } from "@/services/build";
import styles from "./styles.module.css";

type Props = {
  status: BuildStatus;
};

export const StatusIcon = ({ status }: Props) => {
  if (status === "Success")
    return (
      <Image
        src={successIcon}
        alt="success"
        title="success"
        className={styles.icon}
      />
    );
  else if (status === "Failure")
    return (
      <Image
        src={failureIcon}
        alt="failure"
        title="failure"
        className={styles.icon}
      />
    );
  else if (status === "Running")
    return (
      <Image
        src={pendingIcon}
        alt="running"
        title="running"
        className={`${styles.icon} ${styles.running}`}
      />
    );
  else if (status === "Pending")
    return (
      <Image
        src={pendingIcon}
        alt="pending"
        title="pending"
        className={`${styles.icon} ${styles.pending}`}
      />
    );
  else if (status === "Cancelled")
    return (
      <Image
        src={failureIcon}
        alt="cancelled"
        title="cancelled"
        className={`${styles.icon} ${styles.cancelled}`}
      />
    );
  else if (status === "Skipped")
    return (
      <Image
        src={skippedIcon}
        alt="skipped"
        title="skipped"
        className={`${styles.icon} ${styles.skipped}`}
      />
    );
  else return null;
};
