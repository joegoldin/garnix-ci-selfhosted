import DOMPurify from "dompurify";
import { marked } from "marked";
import { Berlin } from "@/utils/fonts";
import styles from "./styles.module.css";

// Module descriptions (and other rendered markdown) link to garnix docs with
// root-relative hrefs like `/docs/...`. Those resolve against the current
// origin, which is right on cloud AND on self-host (the deployment serves its
// docs mirror at /docs on the app domain) — just open them in a new tab.
const rewriteDocLinks = (html: string): string =>
  html.replace(
    /href="(\/docs[^"]*)"/g,
    'href="$1" target="_blank" rel="noopener noreferrer"',
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
