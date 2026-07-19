import { SVGProps } from "react";

// A package/box glyph for build artifacts (garnix.yaml `artifacts:`).
export const ArtifactIcon = (props: SVGProps<SVGSVGElement>) => {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      {...props}
    >
      <path d="M3 8L12 3L21 8V16L12 21L3 16V8Z" />
      <path d="M3 8L12 13L21 8" />
      <path d="M12 13V21" />
    </svg>
  );
};
