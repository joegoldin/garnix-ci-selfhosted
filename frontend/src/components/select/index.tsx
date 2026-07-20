import React from "react";
import { Berlin } from "@/utils/fonts";
import styles from "./styles.module.css";

type Stringifyable =
  | string
  | number
  | boolean
  | null
  | { [s: string]: Stringifyable }
  | Stringifyable[];

type Props<T> = {
  value: T;
  onChange: (s: T) => void;
  // Each option is [value, label, disabled?]; a disabled option is greyed out
  // and non-selectable in the dropdown.
  options: Array<readonly [T, string, boolean?]>;
};

export const Select = <T extends Stringifyable>({
  value,
  onChange,
  options,
}: Props<T>) => (
  <div className={`${styles.container} ${Berlin.className}`}>
    {options.find(([v]) => value === v)?.[1] || "-"}
    <select
      value={JSON.stringify(value)}
      onChange={(e) => onChange(JSON.parse(e.target.value))}
    >
      {options.map(([v, label, disabled]) => (
        <option
          key={JSON.stringify(v)}
          value={JSON.stringify(v)}
          disabled={disabled}
        >
          {label}
        </option>
      ))}
    </select>
  </div>
);
