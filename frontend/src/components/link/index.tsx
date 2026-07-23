"use client";

import _Link, { LinkProps } from "next/link";
import { ButtonHTMLAttributes, DetailedHTMLProps } from "react";
import { MatterSQMono } from "@/utils/fonts";
import styles from "./styles.module.css";

type Props = LinkProps &
  Omit<
    DetailedHTMLProps<
      ButtonHTMLAttributes<HTMLAnchorElement>,
      HTMLAnchorElement
    >,
    "ref"
  > & {
    variant?: "text" | "arrow" | "wrapper";
    eventName?: string;
    target?: string;
    rel?: string;
  };

export const Link = ({
  className,
  children,
  // Dead prop since analytics were removed; destructured (and renamed to the
  // ignore-pattern name) only so it isn't spread onto the DOM via ...rest.
  eventName: _eventName,
  target,
  href,
  variant = "text",
  ...rest
}: Props) => {
  return (
    <_Link
      className={`${className} ${styles.container} ${styles[variant]} ${
        variant === "arrow" && MatterSQMono.className
      }`}
      target={
        target === undefined
          ? href.toString().includes("http")
            ? "_blank"
            : ""
          : target
      }
      href={href}
      {...rest}
    >
      {children}
      {variant === "arrow" && <span className={styles.arrowIcon}>&rarr;</span>}
    </_Link>
  );
};
