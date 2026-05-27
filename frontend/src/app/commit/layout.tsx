import { WithSidebar } from "@/components/withSidebar";

const Layout = ({ children }: { children: React.ReactNode }) => {
  return <WithSidebar>{children}</WithSidebar>;
};

export default Layout;
