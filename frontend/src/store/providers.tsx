"use client";

import { PropsWithChildren } from "react";
import { UserProvider } from "./userContext";
import { ConfigProvider } from "./configContext";

export const Providers = ({ children }: PropsWithChildren) => {
  return (
    <UserProvider>
      <ConfigProvider>{children}</ConfigProvider>
    </UserProvider>
  );
};
