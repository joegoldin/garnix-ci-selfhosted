import { InputProps } from "@/components/input";
import { ToggleSwitch } from "@/components/toggleSwitch";
import { Module } from "@/services/modules";
import { Text } from "@/components/text";
import { Markdown } from "../../markdown";
import styles from "./styles.module.css";

export const ModuleSelector = (
  props: InputProps<Array<string>> & {
    modules: Record<string, Module>;
  },
) => {
  const setValue = (name: string, checkboxEnabled: boolean) => {
    if (checkboxEnabled) {
      props.onChange([...props.value, name]);
    } else {
      props.onChange(props.value.filter((moduleName) => moduleName !== name));
    }
  };
  return Object.entries(props.modules).map(([name, module]) => {
    const value = props.value.includes(name);
    const onChange = (value: boolean) => setValue(name, value);
    return (
      <div
        key={name}
        className={styles.box}
        style={{
          borderColor: value
            ? "var(--color-stone-900)"
            : "var(--color-stone-300)",
          transition: "border 200ms",
        }}
      >
        <Text className={styles.moduleName}>{name} Module</Text>
        <ToggleSwitch
          value={value}
          onChange={() => onChange(!value)}
          className={styles.toggle}
        />
        {module.description != null && (
          <Markdown markdown={module.description} />
        )}
      </div>
    );
  });
};
