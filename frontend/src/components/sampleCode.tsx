import { forwardRef } from "react";
import { Prism as SyntaxHighlighter } from "react-syntax-highlighter";
import {
  oneDark,
  oneLight,
} from "react-syntax-highlighter/dist/esm/styles/prism";

interface Props {
  code: string;
  inverse?: boolean;
  language?: string;
}

const SampleCode = forwardRef<HTMLDivElement, Props>(
  ({ code, inverse, language }: Props, ref) => {
    return (
      <div ref={ref}>
        <SyntaxHighlighter
          language={language || "javascript"}
          style={inverse ? oneDark : oneLight}
          customStyle={{
            background: "transparent",
            padding: 0,
            margin: 0,
            textShadow: "none",
            overflow: "visible",
          }}
          codeTagProps={{ style: { background: "transparent" } }}
        >
          {code}
        </SyntaxHighlighter>
      </div>
    );
  },
);

SampleCode.displayName = "Sample Code";

export { SampleCode };
