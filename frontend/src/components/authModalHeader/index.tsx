"use client";

import Image from "next/image";
import { Link } from "@/components/link";
import docsIcon from "@/components/icons/docs.svg";
import blogIcon from "@/components/icons/blog.svg";
import loginIcon from "@/components/icons/login.svg";
import logoIcon from "@/components/icons/logo.svg";
import { Text } from "@/components/text";
import { ModalSection } from "@/components/modal";
import { useLoginLinkForCurrentPage } from "@/hooks/useLoginLinkForCurrentPage";
import styles from "./styles.module.css";

type Props = {
  type: "login" | "signup";
  className?: string;
};

type LinkProps = {
  text: string;
  icon: string;
  href: string;
  eventName?: string;
};

export const AuthModalHeader = ({ type, className }: Props) => {
  const loginLink = useLoginLinkForCurrentPage().loginLink;

  const LOGIN_LINKS: LinkProps[] = [
    { text: "Docs", icon: docsIcon, href: "https://garnix.io/docs" },
    { text: "Blog", icon: blogIcon, href: "https://garnix.io/blog" },
  ];

  const SIGNUP_LINKS = [
    ...LOGIN_LINKS,
    {
      text: "Log in",
      icon: loginIcon,
      href: loginLink,
      eventName: "log-in-with",
    },
  ];

  return (
    <ModalSection className={`${styles.container} ${className}`}>
      <Link className={styles.titleLink} href="/">
        <Image
          className={styles.logo}
          src={logoIcon}
          alt="share"
          width={118}
          height={20}
        />
      </Link>
      <div className={styles.links}>
        {(type === "login" ? LOGIN_LINKS : SIGNUP_LINKS).map((link) => (
          <Link
            key={link.href}
            className={styles.link}
            href={link.href}
            eventName={link.eventName}
          >
            {link.icon && (
              <Image
                className={styles.icon}
                src={link.icon}
                alt={link.text?.toString() || "icon"}
                width={20}
                height={20}
              />
            )}
            <Text type="span">{link.text}</Text>
          </Link>
        ))}
      </div>
    </ModalSection>
  );
};
