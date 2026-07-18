"use client";

import React from "react";
import { FloatingModal, ModalActions, ModalSection } from "@/components/modal";
import { Text } from "@/components/text";
import { Button } from "@/components/button";
import { RunningServer } from "@/services/servers";
import { useConfig } from "@/store/configContext";
import { CopyableCommand } from "../page";
import styles from "./styles.module.css";

// Best-effort hostname extraction from a server's deployed URL, for use as
// the default entry in the hostname picker below.
const hostnameOf = (url: string): string => {
  try {
    return new URL(url).hostname;
  } catch {
    return url.replace(/^\w+:\/\//, "").replace(/\/.*$/, "");
  }
};

// A declared hostname is wildcard-covered when it equals, or is a strict
// subdomain of, one of the operator's known base domains — mirrors the
// backend's Garnix.Hosting.Domains.classifyDomain.
const wildcardBaseFor = (hostname: string, bases: string[]): string | null =>
  bases.find(
    (base) => hostname === base || hostname.endsWith(`.${base}`),
  ) ?? null;

// The Servers-page (i) DNS-help modal: lets you pick one of a server's
// hostnames (its default deployed URL, or any declared extra domain) and
// shows whether it's already covered by wildcard DNS, or — for a bare custom
// domain — the A/CNAME record you need to add yourself.
export const DomainsModal = ({
  server,
  onRequestClose,
}: {
  server: RunningServer;
  onRequestClose: () => void;
}) => {
  const { hostingPublicIp, hostingDomain, hostingBases } = useConfig();
  const defaultHostname = hostnameOf(server.url);
  const hostnames = Array.from(new Set([defaultHostname, ...server.domains]));
  const [selected, setSelected] = React.useState(defaultHostname);
  const wildcardBase = wildcardBaseFor(selected, hostingBases);

  return (
    <FloatingModal onRequestClose={onRequestClose}>
      <ModalSection>
        <Text type="h1">DNS setup</Text>
        <Text type="p">
          Choose one of {server.package_name}&apos;s hostnames to see whether
          it needs a DNS record.
        </Text>
      </ModalSection>
      <ModalSection>
        <label className={styles.field}>
          <span className={styles.fieldLabel}>Hostname</span>
          <select
            className={styles.select}
            value={selected}
            onChange={(e) => setSelected(e.target.value)}
          >
            {hostnames.map((hostname) => (
              <option key={hostname} value={hostname}>
                {hostname === defaultHostname ? `${hostname} (default)` : hostname}
              </option>
            ))}
          </select>
        </label>
        {wildcardBase ? (
          <Text type="p" className={styles.covered}>
            Wildcard-covered by <Text type="code">{wildcardBase}</Text> — no
            DNS change needed.
          </Text>
        ) : (
          <div className={styles.record}>
            <Text type="p">
              This hostname isn&apos;t covered by wildcard DNS. Add this
              record with your DNS provider:
            </Text>
            {hostingPublicIp ? (
              <CopyableCommand label="A" command={`${selected}    ${hostingPublicIp}`} />
            ) : (
              <CopyableCommand
                label="CNAME"
                command={`${selected}    ${hostingDomain}`}
              />
            )}
          </div>
        )}
      </ModalSection>
      <ModalSection>
        <ModalActions align="right">
          <Button onClick={onRequestClose}>Close</Button>
        </ModalActions>
      </ModalSection>
    </FloatingModal>
  );
};
