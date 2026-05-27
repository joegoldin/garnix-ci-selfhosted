import React from "react";
import { Loading } from "@/components/loading";
import { LoginPrompt } from "@/components/loginPrompt";
import { WithSidebar } from "@/components/withSidebar";
import { useUser } from "@/store/userContext";
import type { NextPage } from "next/types";

export function AppPage(
  PageComponent: NextPage<{ params: Record<string, string> }>,
  opts: { requireAuth?: boolean } = {},
): NextPage<{ params: Record<string, string> }> {
  const Page: NextPage<{ params: Record<string, string> }> = (props) => {
    const { user } = useUser();
    if (user.state === "loading") {
      return (
        <div style={{ marginTop: "50vh", transform: "translate(0,-50%)" }}>
          <Loading />
        </div>
      );
    }
    if (user.state === "logged-in" || !opts.requireAuth) {
      return (
        <WithSidebar>
          <PageComponent {...props} />
        </WithSidebar>
      );
    }
    return (
      <WithSidebar>
        <LoginPrompt />
      </WithSidebar>
    );
  };

  return Page;
}
