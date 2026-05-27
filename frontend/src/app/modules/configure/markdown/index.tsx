import DOMPurify from "dompurify";
import { marked } from "marked";
import { Berlin } from "@/utils/fonts";
import styles from "./styles.module.css";

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
        __html: DOMPurify.sanitize(marked.parse(props.markdown) as string),
      }}
      data-testid="description"
      className={`${Berlin.className} ${styles.markdown}`}
    />
  );
};
