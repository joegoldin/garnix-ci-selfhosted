import { z } from "zod";

export const withPropCheck = <T>(
  p: z.Schema<T>,
  fn: (props: T) => React.ReactNode,
): React.FC<T> => {
  return (props) => fn(p.parse(props));
};
