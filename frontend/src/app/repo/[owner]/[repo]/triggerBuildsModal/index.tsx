"use client";

import React from "react";
import { useRouter } from "next/navigation";
import { Text } from "@/components/text";
import { FloatingModal, ModalActions, ModalSection } from "@/components/modal";
import { Button } from "@/components/button";
import { Loading } from "@/components/loading";
import { useForm } from "@/hooks/useForm";
import { useLoading } from "@/hooks/useLoading";
import { Ok, Err } from "@/services";
import { getBranches, triggerBuild } from "@/services/commit";
import { Berlin } from "@/utils/fonts";
import styles from "./styles.module.css";

// Lists the repo's branches and runs a fresh eval against the chosen branch's
// latest commit. On GitHub the branch list is live and the newest commit is
// resolved server-side; on Gitea it lists branches garnix has already seen and
// re-runs the latest commit it has for that branch.
export const TriggerBuildsModal = (props: {
  owner: string;
  repo: string;
  onRequestClose: () => void;
}) => {
  const router = useRouter();
  const loadBranches = React.useCallback(
    () => getBranches(props.owner, props.repo),
    [props.owner, props.repo],
  );
  const branches = useLoading(loadBranches);
  const [selected, setSelected] = React.useState<string>("");

  // Default the selection to the first branch once they load.
  React.useEffect(() => {
    if (
      selected === "" &&
      !branches.loading &&
      branches.data.ok &&
      branches.data.data.length > 0
    ) {
      setSelected(branches.data.data[0]!);
    }
  }, [branches, selected]);

  const form = useForm({}, async () => {
    if (selected === "") return Err({ message: "Select a branch first." });
    const result = await triggerBuild(props.owner, props.repo, selected);
    if (!result.ok) return result;
    router.push(`/commit/${result.data.commit}`);
    return Ok(null);
  });

  return (
    <FloatingModal onRequestClose={props.onRequestClose}>
      <form {...form.props}>
        <ModalSection>
          <Text type="h1">Trigger Builds</Text>
        </ModalSection>
        <ModalSection
          className={`${styles.mainModalSection} ${Berlin.className}`}
        >
          <p>
            Run a fresh evaluation against the latest commit of a branch — all
            of that commit&apos;s builds and checks are (re)run.
          </p>
          {branches.loading ? (
            <Loading />
          ) : !branches.data.ok ? (
            <Text className={styles.error}>
              Couldn&apos;t load branches: {branches.data.error.message}
            </Text>
          ) : branches.data.data.length === 0 ? (
            <Text>No branches found for this repo yet.</Text>
          ) : (
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Branch</span>
              <select
                className={styles.select}
                value={selected}
                onChange={(e) => setSelected(e.target.value)}
              >
                {branches.data.data.map((b) => (
                  <option key={b} value={b}>
                    {b}
                  </option>
                ))}
              </select>
            </label>
          )}
        </ModalSection>
        <ModalSection>
          {form.result && !form.result.ok && (
            <Text className={styles.error}>{form.result.error.message}</Text>
          )}
          <ModalActions align="right">
            <Button onClick={props.onRequestClose}>Cancel</Button>
            <Button style="primaryInverse" loading={form.loading} submit>
              Trigger
            </Button>
          </ModalActions>
        </ModalSection>
      </form>
    </FloatingModal>
  );
};
