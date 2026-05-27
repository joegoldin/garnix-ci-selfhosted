"use client";

import { Tooltip as InternalTooltip } from "@nextui-org/react";
import { useState } from "react";
import { useWindowSize } from "usehooks-ts";
import { z } from "zod";
import { Text } from "@/components/text";
import { withPropCheck } from "@/utils/withPropCheck";
import styles from "./styles.module.css";

const PropSchema = z.object({
  className: z.string().optional(),
  children: z.custom(),
});

export const ToolTip = withPropCheck(PropSchema, ({ children, className }) => {
  const [isOpen, setIsOpen] = useState(false);
  const { width } = useWindowSize();
  return (
    <InternalTooltip
      content={<Text className={styles.content}>{children}</Text>}
      placement={width > 768 ? "right" : "top"}
      isOpen={isOpen}
    >
      <span
        className={`${className} ${styles.button}`}
        onClick={() => setIsOpen(!isOpen)}
        onMouseEnter={() => setIsOpen(true)}
        onMouseLeave={() => setIsOpen(false)}
      >
        ?
      </span>
    </InternalTooltip>
  );
});
