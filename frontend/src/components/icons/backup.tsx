import { SVGProps } from "react";

export const BackupIcon = (props: SVGProps<SVGSVGElement>) => {
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
      <ellipse cx="12" cy="6" rx="8" ry="3" />
      <path d="M4 6V18C4 19.66 7.58 21 12 21C16.42 21 20 19.66 20 18V6" />
      <path d="M4 12C4 13.66 7.58 15 12 15C16.42 15 20 13.66 20 12" />
    </svg>
  );
};
