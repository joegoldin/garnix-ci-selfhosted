"use client";

import React from "react";
import { WithSidebar } from "@/components/withSidebar";
import { useUser } from "@/store/userContext";

const Page = () => {
  const { logout } = useUser();
  React.useEffect(() => {
    void (async () => {
      await logout();
    })();
  }, [logout]);
  return <WithSidebar />;
};

export default Page;
