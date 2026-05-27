import { match } from "ts-pattern";
import { Build } from "@/services/build";
import { Run } from "@/services/run";

export const formatCommitSha = ({
  gitCommit,
}: {
  gitCommit: string;
}): string => {
  return gitCommit.substring(0, 8);
};

export const formatRunName = (item: Run | Build): string =>
  match(item)
    .with({ tag: "Build" }, (build) => {
      const text = [];
      if (build.packageType !== "overall") text.push(build.packageType);
      text.push(build.package);
      if (build.system) text.push(`[${build.system}]`);
      return text.join(" ");
    })
    .with({ tag: "Run" }, (run) => {
      return run.name;
    })
    .exhaustive();

export const runUrl = (item: Run | Build): string =>
  match(item.tag)
    .with("Build", () => `/build/${item.id}`)
    .with("Run", () => `/run/${item.id}`)
    .exhaustive();

export const nixFieldToHumanReadable = (str: string): string =>
  str.split("").reduce((acc, letter, i) => {
    if (i === 0) return letter.toUpperCase();
    if ("A" <= letter && letter <= "Z") return `${acc} ${letter}`;
    return acc + letter;
  }, "");

export const capitalizeWords = (str: string): string =>
  str
    .split(" ")
    .map((word) => String(word).charAt(0).toUpperCase() + String(word).slice(1))
    .join(" ");

export const stripPrefix = (s: string, prefix: string) => {
  if (s.startsWith(prefix)) {
    return s.slice(prefix.length);
  } else {
    return s;
  }
};
