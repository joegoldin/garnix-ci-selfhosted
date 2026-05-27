import React from "react";
import { createPortal } from "react-dom";

type Props = {
  enable?: boolean;
};

export const Portal = ({
  enable = true,
  children,
}: React.PropsWithChildren<Props>) => {
  const [mounted, setMounted] = React.useState(false);
  React.useEffect(() => {
    setMounted(true);
  }, []);
  return enable && mounted && createPortal(<>{children}</>, document.body);
};
