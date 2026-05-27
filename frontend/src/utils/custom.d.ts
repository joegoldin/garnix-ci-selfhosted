declare module "*.wasm" {
  const value: string;
  export = value;
}

// eslint-disable-next-line no-var
declare var plausible:
  | undefined
  | ((eventName: string, args?: { props: Record<string, string> }) => void);
