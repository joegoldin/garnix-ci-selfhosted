import React from "react";
import { Text } from "@/components/text";
import { Button } from "@/components/button";
import { InputProps } from "@/components/input";
import { TrashIcon } from "@/components/icons/trash";
import styles from "./styles.module.css";

type ListInputProps<T> = InputProps<Array<T>> & {
  label?: string;
  initialElementValue: T;
  renderChild: (props: InputProps<T> & { index: number }) => React.ReactNode;
};

export const ListInput = <T,>(props: ListInputProps<T>) => {
  return (
    <div>
      <Text>{props.label}</Text>
      <ol>
        {props.value.map((item, index) => {
          return (
            <li key={index} className={styles.item}>
              <div>
                {props.renderChild({
                  index,
                  value: item,
                  onChange: (newElementValue) => {
                    props.onChange(
                      props.value.toSpliced(index, 1, newElementValue),
                    );
                  },
                })}
              </div>
              <button
                type="button"
                aria-label="Remove item"
                title="Remove item"
                className={styles.remove}
                onClick={() => {
                  props.onChange(props.value.toSpliced(index, 1));
                }}
              >
                <TrashIcon />
              </button>
            </li>
          );
        })}
      </ol>
      <Button
        submit={false}
        onClick={() => {
          props.onChange([...props.value, props.initialElementValue]);
        }}
      >
        Add Item
      </Button>
    </div>
  );
};
