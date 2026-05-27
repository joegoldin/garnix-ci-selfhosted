import { Berlin } from "@/utils/fonts";
import styles from "./styles.module.css";

type Props = {
  className?: string;
  children: React.ReactNode;
};

export const Table = ({ className, children }: Props) => {
  return (
    <div className={`${styles.container} ${Berlin.className} ${className}`}>
      <table>{children}</table>
    </div>
  );
};
