import { useEffect, useState } from "react";

function featureLocalStorageName(featureName: string) {
  return `garnixfeature${featureName}`;
}

export function featureFlag(name: string): boolean {
  return (
    typeof window == "object" &&
    window.localStorage.getItem(featureLocalStorageName(name)) === "true"
  );
}

if (typeof window == "object") {
  // @ts-ignore
  window.__garnixSetFeatureFlag = (name: string, value: boolean) => {
    window.localStorage.setItem(
      featureLocalStorageName(name),
      JSON.stringify(value),
    );
  };
}

export function useFeatureFlag(name: string): boolean {
  const [flag, setFlag] = useState(false);
  useEffect(() => {
    setFlag(featureFlag(name));
  }, [name]);
  return flag;
}
