import DOMPurify from "dompurify";
import { marked } from "marked";
import { Berlin } from "@/utils/fonts";
import styles from "./styles.module.css";

// Module descriptions (and other rendered markdown) link to garnix docs with
// root-relative hrefs like `/docs/...`. Those resolve against the current
// origin, which on a self-hosted instance has no `/docs` site — the links
// 404. Rewrite them to the canonical upstream docs (absolute links work in
// both cloud and self-host) and open them in a new tab.
const rewriteDocLinks = (html: string): string =>
  html.replace(
    /href="(\/docs[^"]*)"/g,
    'href="https://garnix.io$1" target="_blank" rel="noopener noreferrer"',
  );

export const Markdown = (props: { markdown: string }) => {
  if (!DOMPurify.isSupported) {
    return (
      <div className={`${Berlin.className} ${styles.markdown}`}>
        {props.markdown}
      </div>
    );
  }
  return (
    <div
      dangerouslySetInnerHTML={{
        __html: rewriteDocLinks(
          DOMPurify.sanitize(marked.parse(props.markdown) as string),
        ),
      }}
      data-testid="description"
      className={`${Berlin.className} ${styles.markdown}`}
    />
  );
};
