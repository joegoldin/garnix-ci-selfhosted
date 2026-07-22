import Image from "next/image";
import { useState } from "react";
import dashIcon from "@/components/icons/dash.svg";
import crossIcon from "@/components/icons/cross.svg";
import { Link } from "@/components/link";
import { Text } from "@/components/text";
import { WaitNode } from "@/services/waiting";
import styles from "./styles.module.css";

const WaitingNode = ({ node, depth }: { node: WaitNode; depth: number }) => {
  const [expanded, setExpanded] = useState(false);
  const expandable = node.children.length > 0;

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
        <span className={styles.kind}>{node.kind}</span>
        <span className={node.kind === "derivation" ? styles.derivation : styles.label}>
          {node.href ? <Link href={node.href}>{node.label}</Link> : node.label}
        </span>
        {node.detail ? <span className={styles.detail}>{node.detail}</span> : null}
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
