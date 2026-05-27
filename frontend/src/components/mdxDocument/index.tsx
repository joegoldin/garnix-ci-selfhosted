import { MDXRemote } from "next-mdx-remote/rsc";
import Head from "next/head";
import { Berlin } from "@/utils/fonts";
import { Link } from "@/components/link";
import { Text } from "@/components/text";
import { Terminal } from "@/components/terminal";
import { SampleCode } from "@/components/sampleCode";
import { ToolTip } from "@/components/tooltip";
import { MDXHeader } from "@/components/mdxDocument/header";
import styles from "./styles.module.css";

type Props = {
  source: string;
  className?: string;
  isBlog?: boolean;
};

export const MDXDocument = ({ source, className, isBlog }: Props) => {
  return (
    <section className={`${className} ${styles.container}`}>
      <MDXRemote
        source={source}
        options={{ parseFrontmatter: true }}
        components={{
          a: (props) => (
            <Link className={styles.link} href={props.href || ""}>
              {props.children}
            </Link>
          ),
          strong: (props) => (
            <strong
              {...props}
              className={`${props.className} ${styles.strong}`}
            >
              {props.children}
            </strong>
          ),
          em: (props) => (
            <em {...props} className={`${props.className} ${styles.em}`}>
              {props.children}
            </em>
          ),
          ToolTip: (props) => (
            <ToolTip
              {...props}
              className={`${props.className} ${styles.tooltip}`}
            >
              {props.children}
            </ToolTip>
          ),
          p: (props) => (
            <Text
              type="p"
              {...props}
              className={`${props.className} ${styles.p} ${
                isBlog ? styles.blog : ""
              }`}
            >
              {props.children}
            </Text>
          ),
          h1: (props) => (
            <MDXHeader
              type="h1"
              className={`${props.className} ${styles.h1} ${
                isBlog ? styles.blog : ""
              }`}
              {...props}
            />
          ),
          h2: (props) => (
            <MDXHeader
              type="h2"
              {...props}
              className={`${props.className} ${styles.h2} ${
                isBlog ? styles.blog : ""
              }`}
            />
          ),
          h3: (props) => (
            <MDXHeader
              type="h3"
              {...props}
              className={`${props.className} ${styles.h3} ${
                isBlog ? styles.blog : ""
              }`}
            />
          ),
          ul: (props) => (
            <ul
              {...props}
              className={`${props.className} ${styles.ul} ${Berlin.className} ${
                isBlog ? styles.blog : ""
              }`}
            >
              {props.children}
            </ul>
          ),
          ol: (props) => (
            <ol
              {...props}
              className={`${props.className} ${styles.ol} ${
                isBlog ? styles.blog : ""
              }`}
            >
              {props.children}
            </ol>
          ),
          li: (props) => (
            <li
              {...props}
              className={`${props.className} ${styles.li} ${Berlin.className} ${
                isBlog ? styles.blog : ""
              }`}
            >
              {props.children}
            </li>
          ),
          code: (props) =>
            props.className ? (
              <Terminal
                {...props}
                className={`${props.className} ${styles.terminal}`}
                text={
                  <SampleCode
                    code={props.children?.toString() || ""}
                    language={
                      props.className.includes("language-")
                        ? props.className.split("language-")[1]
                        : "javascript"
                    }
                  />
                }
              />
            ) : (
              <Text type="code" className={`${props.className} ${styles.code}`}>
                {props.children}
              </Text>
            ),
          InlineCode: (props) => (
            <Text
              type="code"
              className={`${props.className} ${styles.code}`}
              style={{ background: "#ddd", padding: 5 }}
            >
              {props.children}
            </Text>
          ),
          Table: (props) => (
            <table {...props} className={`${styles.table} ${Berlin.className}`}>
              {props.children}
            </table>
          ),
          Tr: (props) => (
            <tr {...props} className={styles.tr}>
              {props.children}
            </tr>
          ),
          Td: (props) => (
            <td {...props} className={styles.td}>
              {props.children}
            </td>
          ),
          Th: (props) => (
            <th
              {...props}
              className={`${styles.th} ${Berlin.className} ${styles.strong}`}
            >
              {props.children}
            </th>
          ),
          Link: ({ children, ...rest }) => (
            <Link className={styles.link} {...rest}>
              {children}
            </Link>
          ),
          Head,
          Text,
        }}
      />
    </section>
  );
};
