import React from "react";
import { Button } from "@/components/button";
import { InputProps } from "@/components/input";
import { stripPrefix } from "@/utils/format";
import styles from "./styles.module.css";
import { AddPackageModal } from "./addPackageModal";

const Package = (props: { name: string; onRequestRemove: () => void }) => (
  <div className={styles.pkg}>
    {props.name} <button onClick={props.onRequestRemove}>×</button>
  </div>
);

export const ListOfPackages = (props: InputProps<Array<string>>) => {
  const [showModal, setShowModal] = React.useState(false);
  return (
    <>
      <div className={styles.packageList}>
        {props.value.map((packageName, idx) => (
          <Package
            key={packageName}
            name={stripPrefix(packageName, "pkgs.")}
            onRequestRemove={() => {
              props.onChange(
                props.value.slice(0, idx).concat(props.value.slice(idx + 1)),
              );
            }}
          />
        ))}
      </div>
      {showModal && (
        <AddPackageModal
          value={props.value}
          onChange={props.onChange}
          onRequestClose={() => setShowModal(false)}
        />
      )}
      <Button onClick={() => setShowModal(true)}>Add Packages</Button>
    </>
  );
};
