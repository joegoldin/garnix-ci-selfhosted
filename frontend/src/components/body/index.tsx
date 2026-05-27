"use client";

import { PropsWithChildren } from "react";
import { MatterSQMono } from "@/utils/fonts";

export const Body = ({ children }: PropsWithChildren) => {
  return <body className={MatterSQMono.className}>{children}</body>;
};
