import React from "react";
import styles from "./styles.module.css";

export const Expander = (props: {
  isOpen: boolean;
  children: React.ReactNode;
}) => {
  const measurementRef = React.useRef<HTMLDivElement | null>(null);
  const [height, setHeight] = React.useState<"auto" | number>(
    props.isOpen ? "auto" : 0,
  );
  React.useEffect(() => {
    if (!measurementRef.current) return;
    if (props.isOpen) setHeight(measurementRef.current.scrollHeight);
    else setHeight(0);
  }, [props.isOpen]);
  return (
    <div className={styles.root} style={{ height }}>
      <div ref={measurementRef}>{props.children}</div>
    </div>
  );
};
