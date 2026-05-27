import React from "react";
import Image from "next/image";
import { AgeWasm, initAgeWasm } from "@/age-wasm-compiled/index";
import ageWasmUrl from "@/age-wasm-compiled/age.wasm";
import { TextInput, InputProps } from "@/components/input";
import { Text } from "@/components/text";
import { Ok } from "@/services";
import { FloatingModal, ModalActions, ModalSection } from "@/components/modal";
import { useField, useForm } from "@/hooks/useForm";
import { Button } from "@/components/button";
import { EncryptedSecret, Repo } from "@/services/modules";
import { getRepoKey } from "@/services/keys";
import lockIcon from "@/components/icons/lock.svg";
import styles from "./styles.module.css";

let ageWasmPromise: Promise<AgeWasm> | null = null;

const fetchAgeWasm = async (): Promise<AgeWasm> => {
  if (ageWasmPromise == null) {
    ageWasmPromise = initAgeWasm(fetch(ageWasmUrl));
  }
  return await ageWasmPromise;
};

export const SecretInput = (
  props: InputProps<EncryptedSecret | null> & {
    label?: string;
    placeholder?: string;
    repo: Repo | null;
  },
) => {
  const [modalOpen, setModalOpen] = React.useState(false);
  if (props.repo == null) {
    return (
      <div className={styles.error}>
        <Text>Select a repo above set secrets</Text>
      </div>
    );
  }
  return (
    <div className={styles.root}>
      {props.value != null && (
        <div className={styles.encrypted}>
          <Image src={lockIcon} alt="" />
          <Text>
            Encrypted for <FormatRepo repo={props.value.encryptedFor} />
          </Text>
        </div>
      )}
      <Button onClick={() => setModalOpen(true)}>
        {props.value == null ? "Set secret" : "Update secret"}
      </Button>
      {modalOpen && (
        <SetSecretModal
          onSubmit={(encrypted) => {
            props.onChange(encrypted);
            setModalOpen(false);
          }}
          onRequestClose={() => setModalOpen(false)}
          repo={props.repo}
        />
      )}
    </div>
  );
};

const SetSecretModal = (props: {
  onSubmit: (encrypted: EncryptedSecret) => void;
  onRequestClose: () => void;
  repo: Repo;
}) => {
  const secret = useField("");
  const form = useForm({ secret }, async ({ secret }) => {
    const repo = props.repo;
    const [ageWasm, repoKey] = await Promise.all([
      fetchAgeWasm(),
      getRepoKey(repo),
    ]);
    const result = ageWasm.encrypt(repoKey, secret);
    if (!result.ok) return result;
    props.onSubmit({ encryptedFor: repo, encryptedValue: result.data });
    return Ok(null);
  });
  return (
    <FloatingModal onRequestClose={props.onRequestClose}>
      <form {...form.props} data-testid="set-secret-form">
        <ModalSection>
          <Text type="h1">Encrypt secret</Text>
        </ModalSection>
        <ModalSection>
          <Text type="p">
            Once saved, this secret will be encrypted in your browser using{" "}
            <a href="https://github.com/FiloSottile/age">age</a> for{" "}
            <FormatRepo repo={props.repo} />. Your secrets will never be sent on
            our servers in the clear.
          </Text>
          <Text type="p">
            If you change your source repository, the secrets will be invalid
            and will need to be reentered.
          </Text>
          <br />
          <TextInput {...secret.props} placeholder="Secret value" />
        </ModalSection>
        <ModalSection>
          <ModalActions align="right">
            <Button style="secondary" onClick={props.onRequestClose}>
              Cancel
            </Button>
            <Button style="primaryInverse" submit loading={form.loading}>
              Save
            </Button>
          </ModalActions>
        </ModalSection>
      </form>
    </FloatingModal>
  );
};

const FormatRepo = (props: { repo: Repo }) => (
  <>
    <strong>{props.repo.repoUser}</strong>/
    <strong>{props.repo.repoName}</strong>
  </>
);
