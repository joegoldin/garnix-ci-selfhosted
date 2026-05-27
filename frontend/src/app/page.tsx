"use client";

import { CommitList } from "@/components/commitList";
import { AppPage } from "@/utils/appPage";

const Home = () => {
  return <CommitList for="reqUser" />;
};

export default AppPage(Home, { requireAuth: true });
