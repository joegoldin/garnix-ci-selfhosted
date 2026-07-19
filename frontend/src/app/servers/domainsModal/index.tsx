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
  bases.find((base) => hostname === base || hostname.endsWith(`.${base}`)) ??
  null;

// The DNS-help modal. With a `server`, it lets you pick one of that server's
// hostnames (its default deployed URL, or any declared extra domain) and shows
// whether it's already wildcard-covered or — for a bare custom domain — the
// A/CNAME record you need to add. Without a server (the Connect-column header
// (i)), it explains generally how to point a custom or vanity domain here.
export const DomainsModal = ({
  server,
  onRequestClose,
}: {
  server?: RunningServer;
  onRequestClose: () => void;
}) => {
  const { hostingPublicIp, hostingDomain, hostingBases } = useConfig();
  const defaultHostname = server ? hostnameOf(server.url) : "";
  const [selected, setSelected] = React.useState(defaultHostname);

  // The DNS record to add for a not-wildcard-covered hostname: an A record to
  // the hosting host's public IP when known, else a CNAME to the hosting domain.
  const recordFor = (name: string) =>
    hostingPublicIp ? (
      <CopyableCommand label="A" command={`${name}    ${hostingPublicIp}`} />
    ) : (
      <CopyableCommand label="CNAME" command={`${name}    ${hostingDomain}`} />
    );

  if (!server) {
    return (
      <FloatingModal onRequestClose={onRequestClose}>
        <ModalSection>
          <Text type="h1">Custom &amp; vanity domains</Text>
          <Text type="p">
            Point your own domain at your garnix-hosted servers.
          </Text>
        </ModalSection>
        {hostingBases.length > 0 ? (
          <ModalSection>
            <Text type="p">
              These base domains are wildcard-covered — any subdomain (e.g.{" "}
              <Text type="code">myapp.{hostingBases[0]}</Text>) resolves
              automatically, no DNS change needed:
            </Text>
            <ul className={styles.baseList}>
              {hostingBases.map((base) => (
                <li key={base}>
                  <Text type="code">{base}</Text>
                </li>
              ))}
            </ul>
          </ModalSection>
        ) : null}
        <ModalSection>
          <Text type="p">
            For a fully custom domain, add this record with your DNS provider,
            then declare the domain in your server&apos;s{" "}
            <Text type="code">domains:</Text> list in garnix.yaml (or add it
            under Configure → Connected domains):
          </Text>
          {recordFor("<your-domain>")}
        </ModalSection>
        <ModalSection>
          <ModalActions align="right">
            <Button onClick={onRequestClose}>Close</Button>
          </ModalActions>
        </ModalSection>
      </FloatingModal>
    );
  }

  const hostnames = Array.from(new Set([defaultHostname, ...server.domains]));
  const wildcardBase = wildcardBaseFor(selected, hostingBases);

  return (
    <FloatingModal onRequestClose={onRequestClose}>
      <ModalSection>
        <Text type="h1">DNS setup</Text>
        <Text type="p">
          Choose one of {server.package_name}&apos;s hostnames to see whether it
          needs a DNS record.
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
                {hostname === defaultHostname
                  ? `${hostname} (default)`
                  : hostname}
              </option>
            ))}
          </select>
        </label>
        {wildcardBase ? (
          <Text type="p" className={styles.covered}>
            Wildcard-covered by <Text type="code">{wildcardBase}</Text> — no DNS
            change needed.
          </Text>
        ) : (
          <div className={styles.record}>
            <Text type="p">
              This hostname isn&apos;t covered by wildcard DNS. Add this record
              with your DNS provider:
            </Text>
            {recordFor(selected)}
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
