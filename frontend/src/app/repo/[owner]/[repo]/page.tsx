"use client";

import React from "react";
import { WithSidebar } from "@/components/withSidebar";
import { CommitList } from "@/components/commitList";

const Page = ({ params }: { params: { owner: string; repo: string } }) => {
  return (
    <WithSidebar>
      <CommitList for={params} />
    </WithSidebar>
  );
};

export default Page;
