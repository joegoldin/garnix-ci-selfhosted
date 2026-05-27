import { ReactNode, isValidElement } from "react";
import Image from "next/image";
import { z } from "zod";
import { Link } from "@/components/link";
import { Text } from "@/components/text";
import shareIcon from "@/components/icons/share.svg";
import { withPropCheck } from "@/utils/withPropCheck";
import styles from "./styles.module.css";

const PropSchema = z.object({
  type: z.enum(["h1", "h2", "h3"]),
  className: z.string().optional(),
  children: z.custom(),
});

export const MDXHeader = withPropCheck(
  PropSchema,
  ({ type, className, children }) => {
    const id = getId(children);
    return (
      <Text type={type} className={`${className} ${styles.container}`}>
        <a id={id} className={styles.anchorTarget} />
        <Link href={`#${id}`} className={styles.link}>
          <span>{children}</span>
          <Image
            className={styles.share}
            src={shareIcon}
            alt="share"
            width={16}
            height={16}
          />
        </Link>
      </Text>
    );
  },
);

const getId = (children: ReactNode): string => {
  if (!children) return "undefined";
  if (["string", "number"].includes(typeof children))
    return `${children}`
      .trim()
      .toLowerCase()
      .replace(/[^a-zA-Z0-9]+/g, "-");
  else if (children instanceof Array) {
    return children.map(getId).join("-");
  } else if (isValidElement(children)) {
    return getId(children.props.children);
  }
  return children.toString();
};
