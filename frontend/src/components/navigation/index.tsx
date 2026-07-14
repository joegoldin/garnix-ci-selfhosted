"use client";

import Image from "next/image";
import { usePathname, useRouter } from "next/navigation";
import React from "react";
import { AppRouterInstance } from "next/dist/shared/lib/app-router-context.shared-runtime";
import { Link } from "@/components/link";
import { Text } from "@/components/text";
import logoIcon from "@/components/icons/logo.svg";
import { BuildsIcon } from "@/components/icons/builds";
import { ModulesIcon } from "@/components/icons/modules";
import { ServerIcon } from "@/components/icons/servers";
import { DocumentationIcon } from "@/components/icons/documentation";
import { AccountIcon } from "@/components/icons/account";
import { SettingsIcon } from "@/components/icons/settings";
import { LogoutIcon } from "@/components/icons/logout";
import hamburgerMenuIcon from "@/components/icons/hamburgerMenu.svg";
import { trackClick } from "@/utils/analytics";
import { filterNull } from "@/utils";
import styles from "./styles.module.css";

type Props = {
  className?: string;
};

type LinkProps = BasicLinkProps &
  (
    | {
        href: string;
        onClick?: undefined;
      }
    | {
        onClick: () => void;
        href?: undefined;
      }
  );

type BasicLinkProps = {
  icon: React.ReactNode;
  label: string;
  openNewPage?: boolean;
  eventName?: string;
};

const MAIN_LINK_GROUP: Array<LinkProps> = filterNull([
  {
    icon: <BuildsIcon className={styles.icon} />,
    label: "Builds",
    href: "/",
  },
  {
    icon: <ServerIcon className={styles.icon} />,
    label: "Servers",
    href: "/servers",
  },
  {
    icon: <ModulesIcon className={styles.icon} />,
    label: "Modules",
    href: "/modules/configure",
  },
  {
    icon: <DocumentationIcon className={styles.icon} />,
    label: "Documentation",
    href: "/docs",
    openNewPage: true,
  },
]);

const ACCOUNT_LINK_GROUP = (router: AppRouterInstance): LinkProps[] => [
  {
    icon: <AccountIcon className={styles.icon} />,
    label: "Account",
    href: "/account",
  },
  {
    icon: <SettingsIcon className={styles.icon} />,
    label: "Configure",
    href: "/configure",
    eventName: "configure",
  },
  {
    icon: <LogoutIcon className={styles.icon} />,
    label: "Logout",
    onClick: () => {
      trackClick("log-out");
      router.push("/logout");
    },
  },
];

export const Navigation = ({ className }: Props) => {
  const pathname = usePathname();
  const [menuOpen, setMenuOpen] = React.useState(false);
  const router = useRouter();
  return (
    <div className={`${styles.container} ${className}`}>
      <div className={styles.header}>
        <Link href="/">
          <Image
            className={styles.logo}
            src={logoIcon}
            alt="share"
            width={118}
            height={20}
          />
        </Link>
        <Image
          src={hamburgerMenuIcon}
          alt="menu"
          className={styles.menu}
          onClick={() => {
            trackClick("logged-in-menu");
            setMenuOpen(!menuOpen);
          }}
        />
      </div>
      {/* <div className={`${styles.inputContainer} ${Berlin.className}`}>
        <input className={styles.input} placeholder="Search" />
        <div className={styles.hints}>
          <div className={styles.hint}>&#8984;</div>
          <div className={styles.hint}>K</div>
        </div>
      </div> */}
      <div
        className={`${styles.linkGroupContainer} ${menuOpen && styles.open}`}
      >
        <div className={styles.linkGroup}>
          {MAIN_LINK_GROUP.map((link) => (
            <NavLink key={link.label} link={link} pathname={pathname} />
          ))}
        </div>
        <div>
          <div className={styles.linkGroup}>
            {ACCOUNT_LINK_GROUP(router).map((link) => (
              <NavLink key={link.label} link={link} pathname={pathname} />
            ))}
          </div>
        </div>
      </div>
    </div>
  );
};

const NavLink = ({
  link,
  pathname,
  useStroke,
}: {
  link: LinkProps;
  pathname: string;
  useStroke?: boolean;
}) => {
  const wrapper = (children: React.ReactNode) => {
    if (link.href)
      return (
        <Link
          href={link.href}
          eventName={link.eventName}
          className={`${styles.linkContainer} ${
            link.href === pathname && styles.active
          } ${useStroke ? styles.stroke : styles.fill}`}
          target={link.openNewPage ? "_blank" : ""}
        >
          {children}
        </Link>
      );
    return (
      <button
        onClick={() => {
          link.eventName && trackClick(link.eventName);
          link.onClick && link.onClick();
        }}
        className={`${styles.linkContainer} ${styles.button} ${
          useStroke ? styles.stroke : styles.fill
        }`}
      >
        {children}
      </button>
    );
  };
  return wrapper(
    <>
      <span className={styles.link}>
        {link.icon}
        <Text type="span">{link.label}</Text>
      </span>
    </>,
  );
};
