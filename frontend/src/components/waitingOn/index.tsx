import Image from "next/image";
import { useState } from "react";
import dashIcon from "@/components/icons/dash.svg";
import crossIcon from "@/components/icons/cross.svg";
import { Link } from "@/components/link";
import { StatusIcon } from "@/components/statusIcon";
import { Text } from "@/components/text";
import { WaitNode } from "@/services/waiting";
import { formatBytes } from "@/utils/format";
import styles from "./styles.module.css";

const formatTransferDetail = (detail: string | null): string | null => {
  if (detail == null) return null;
  const progress = detail.match(/^(\d+)\s*\/\s*(\d+)$/);
  if (progress == null) return detail;

  const transferred = Number(progress[1]);
  const total = Number(progress[2]);
  if (!Number.isSafeInteger(transferred) || !Number.isSafeInteger(total)) {
    return detail;
  }

  return total === 0
    ? formatBytes(transferred)
    : `${formatBytes(transferred)} / ${formatBytes(total)}`;
};

const WaitingNode = ({ node, depth }: { node: WaitNode; depth: number }) => {
  const [expanded, setExpanded] = useState(false);
  const expandable = node.children.length > 0;
  const running =
    node.lastActivityAt != null || node.detail?.toLowerCase() === "running";
  const displayKind = node.kind === "realize" ? "prepare" : node.kind;
  const displayLabel =
    node.kind === "realize" && node.label.trim() === ""
      ? "store paths"
      : node.label;
  const displayDetail =
    node.kind === "transfer" ? formatTransferDetail(node.detail) : node.detail;

  return (
    <li className={styles.node}>
      <div
        className={styles.row}
        style={{ paddingLeft: `${12 + depth * 20}px` }}
      >
        {expandable ? (
          <button
            type="button"
            className={styles.toggle}
            aria-label={`${expanded ? "Collapse" : "Expand"} ${node.label}`}
            aria-expanded={expanded}
            onClick={() => setExpanded((value) => !value)}
          >
            <Image
              src={expanded ? dashIcon : crossIcon}
              alt={expanded ? "close" : "open"}
              className={styles.toggleIcon}
            />
          </button>
        ) : (
          <span className={styles.togglePlaceholder} aria-hidden="true" />
        )}
        {running ? (
          <span className={styles.running}>
            <StatusIcon status="Running" />
          </span>
        ) : (
          <span className={styles.runningPlaceholder} aria-hidden="true" />
        )}
        <span className={styles.kind}>{displayKind}</span>
        <span className={node.kind === "derivation" ? styles.derivation : styles.label}>
          {node.href ? <Link href={node.href}>{displayLabel}</Link> : displayLabel}
        </span>
        {displayDetail ? <span className={styles.detail}>{displayDetail}</span> : null}
      </div>
      {expanded ? (
        <ul className={styles.children}>
          {node.children.map((child) => (
            <WaitingNode key={child.id} node={child} depth={depth + 1} />
          ))}
        </ul>
      ) : null}
    </li>
  );
};

export const WaitingOn = ({ nodes }: { nodes: WaitNode[] }) => {
  if (nodes.length === 0) return null;

  return (
    <div>
      <Text type="h2" className={styles.heading}>
        Waiting on
      </Text>
      <ul className={styles.tree}>
        {nodes.map((node) => (
          <WaitingNode key={node.id} node={node} depth={0} />
        ))}
      </ul>
    </div>
  );
};
