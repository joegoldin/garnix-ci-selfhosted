import React from "react";
import { TextInput, InputProps } from "@/components/input";
import { addPlaceholderEg } from "../page";

export const PathInput = (
  props: InputProps<string> & {
    label?: string;
    placeholder?: string;
  },
) => {
  const [rawPath, setRawPath] = React.useState(humanize(props.value));
  return (
    <TextInput
      label={props.label}
      placeholder={addPlaceholderEg(
        props.placeholder === undefined
          ? undefined
          : humanize(props.placeholder),
      )}
      value={rawPath}
      onChange={(value) => {
        setRawPath(value);
        props.onChange(_normalize(value));
      }}
    />
  );
};

export const _normalize = (path: string): string => {
  if (path.startsWith("/")) path = `.${path}`;
  while (path.endsWith("/")) path = path.slice(0, -1);
  if (!path.startsWith("./")) path = `./${path}`;
  return path;
};

const humanize = (path: string): string => {
  const prefix = "./";
  if (path.startsWith(prefix)) {
    return path.slice(prefix.length);
  }
  return path;
};
