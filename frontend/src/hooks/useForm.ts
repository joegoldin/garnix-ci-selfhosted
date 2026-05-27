import React from "react";
import { z } from "zod";
import { Err, Result } from "@/services";

type ThrowInOnSubmitError = { type: "throw-in-on-submit"; message: string };

export type Field<T> = {
  value: T;
  setDisabled: (disabled: boolean) => void;
  clear: () => void;
  props: { value: T; disabled: boolean; onChange: (t: T) => void };
};

export type Form<Err> = {
  loading: boolean;
  result: null | Result<null, Err | ThrowInOnSubmitError>;
  props: React.FormHTMLAttributes<HTMLFormElement>;
};

export const useField = <T>(initial: T): Field<T> => {
  const [value, setValue] = React.useState(initial);
  const [disabled, setDisabled] = React.useState(false);
  return {
    value,
    setDisabled,
    clear: () => setValue(initial),
    props: {
      value,
      disabled,
      onChange: setValue,
    },
  };
};

type GetFieldType<T> = T extends Field<infer U> ? U : never;

export const useForm = <Fields extends Record<string, Field<any>>, Err>(
  fields: Fields,
  onSubmit: (
    values: {
      [k in keyof Fields]: GetFieldType<Fields[k]>;
    },
    submitAction: string | null,
  ) => Promise<Result<null, Err>>,
): Form<Err> => {
  const isMounted = React.useRef(true);
  const [result, setResult] = React.useState<null | Result<
    null,
    Err | ThrowInOnSubmitError
  >>(null);
  const [loading, setLoading] = React.useState(false);
  React.useEffect(() => {
    return () => {
      isMounted.current = false;
    };
  }, []);
  const setIsSubmitting = (isSubmitting: boolean) => {
    setLoading(isSubmitting);
    Object.values(fields).forEach((f) => f.setDisabled(isSubmitting));
  };
  return {
    loading,
    result,
    props: {
      onSubmit: (e) => {
        e.preventDefault();
        e.stopPropagation();
        const submitAction =
          (e.nativeEvent as SubmitEvent).submitter?.getAttribute(
            "data-submit-action",
          ) ?? null;
        void (async () => {
          setIsSubmitting(true);
          try {
            const result = await onSubmit(
              Object.entries(fields).reduce(
                (acc, [name, field]) => {
                  return { ...acc, [name]: field.value };
                },
                {} as { [k in keyof Fields]: GetFieldType<Fields[k]> },
              ),
              submitAction,
            );
            if (!isMounted.current) return;
            setResult(result);
          } catch (err) {
            const parsed = z.object({ message: z.string() }).safeParse(err);
            const message = parsed.success
              ? parsed.data.message
              : JSON.stringify(err);
            setResult(Err({ type: "throw-in-on-submit", message }));
          }
          setIsSubmitting(false);
        })();
      },
    },
  };
};
