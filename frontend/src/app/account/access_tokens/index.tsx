"use client";
import React, { PropsWithChildren } from "react";
import { P, match } from "ts-pattern";
import endent from "endent";
import { Table } from "@/components/table";
import { Text } from "@/components/text";
import { Button } from "@/components/button";
import { FloatingModal, ModalActions, ModalSection } from "@/components/modal";
import { Field, useField, useForm } from "@/hooks/useForm";
import { TextInput } from "@/components/input";
import { Err, Ok } from "@/services";
import { SampleCode } from "@/components/sampleCode";
import { useLoading } from "@/hooks/useLoading";
import {
  AccountTokenScopes,
  generateAccessToken,
  getAccessTokens,
  revokeAccessToken,
} from "@/services/account";
import { useUser } from "@/store/userContext";
import { useConfig } from "@/store/configContext";
import { Link } from "@/components/link";
import { Berlin } from "@/utils/fonts";
import { ToggleSwitch } from "@/components/toggleSwitch";
import styles from "./styles.module.css";

type ModalState =
  | { t: "closed" }
  | { t: "new-token" }
  | { t: "generated"; token: string; scopes: AccountTokenScopes };

export const AccessTokensComponent = () => {
  const [modalState, setModalState] = React.useState<ModalState>({
    t: "closed",
  });

  const loadingTokens = useLoading(getAccessTokens);
  if (loadingTokens.loading) return null;

  return (
    <>
      <div className={styles.header}>
        <Text type="h2">Access Tokens</Text>
        <Button onClick={() => setModalState({ t: "new-token" })}>
          Create new access token
        </Button>
      </div>
      <Table className={styles.table}>
        <thead>
          <tr>
            <th>Token name</th>
            <th>Created</th>
            <th>Cache Access</th>
            <th>API Access</th>
            <th>Last Used</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {match(loadingTokens.data)
            .with(Err(P.select()), (err) => (
              <tr>
                <td colSpan={6}>
                  Failed to fetch access tokens: {err.message}
                </td>
              </tr>
            ))
            .with(Ok({ tokens: [] }), () => (
              <tr>
                <td colSpan={6}>You have no access tokens</td>
              </tr>
            ))
            .with(Ok({ tokens: P.select() }), (tokens) =>
              tokens.map((token) => (
                <tr key={token.id}>
                  <td>{token.name}</td>
                  <td>{token.created.toLocaleString()}</td>
                  <td>
                    <ScopeIcon value={token.scopes.cache} />
                  </td>
                  <td>
                    <ScopeIcon value={token.scopes.api} />
                  </td>
                  <td>{token.last_used?.toLocaleString() ?? "Never"}</td>
                  <td>
                    <RevokeButton
                      tokenId={token.id}
                      onRevoked={loadingTokens.reload}
                    />
                  </td>
                </tr>
              )),
            )
            .exhaustive()}
        </tbody>
      </Table>
      <div className={`${Berlin.className} ${styles.small}`}>
        You can use access tokens to authenticate youself for{" "}
        <Link href="/docs/ci/caching#private-caches">
          private caches
        </Link>
        , and{" "}
        <Link href="/docs/api">our programmatic API</Link>.
      </div>
      {modalState.t === "new-token" && (
        <NewTokenModal
          onRequestClose={() => setModalState({ t: "closed" })}
          onGenerated={(token, scopes) => {
            setModalState({ t: "generated", token, scopes });
            loadingTokens.reload();
          }}
        />
      )}
      {modalState.t === "generated" && (
        <DisplayGeneratedTokenModal
          token={modalState.token}
          accountTokenScopes={modalState.scopes}
          onRequestClose={() => setModalState({ t: "closed" })}
        />
      )}
    </>
  );
};

const ScopeIcon = (props: { value: boolean }) => {
  const checkmark = (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      width="16"
      height="16"
      viewBox="0 0 16 16"
      fill="none"
    >
      <path
        d="M13.3333 4.33325L5.99996 11.6666L2.66663 8.33325"
        stroke="#000"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );

  const cross = (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      width="16"
      height="16"
      viewBox="0 0 16 16"
      fill="none"
    >
      <g>
        <path
          d="M5.33337 5.33325L10.6667 10.6666"
          stroke="#000"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M10.6667 5.33325L5.33337 10.6666"
          stroke="#000"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </g>
    </svg>
  );

  return props.value ? checkmark : cross;
};

const RevokeButton = (props: { tokenId: number; onRevoked: () => void }) => {
  const form = useForm({}, async () => {
    const res = await revokeAccessToken(props.tokenId);
    if (!res.ok) return res;
    props.onRevoked();
    return Ok(null);
  });
  return (
    <form {...form.props}>
      <Button submit loading={form.loading} style="warning">
        Revoke
      </Button>
    </form>
  );
};

const NewTokenModal = (props: {
  onRequestClose: () => void;
  onGenerated: (token: string, scopes: AccountTokenScopes) => void;
}) => {
  const name = useField("");
  const scopeCache = useField(true);
  const scopeApi = useField(false);
  const form = useForm(
    { name, scopeCache, scopeApi },
    async ({ name, scopeCache, scopeApi }) => {
      if (name.trim() === "") {
        return Err({ message: "Please, provide a name!" });
      }
      if (!scopeApi && !scopeCache) {
        return Err({ message: "Please, select at least one scope!" });
      }
      const scopes = { cache: scopeCache, api: scopeApi };
      const res = await generateAccessToken({
        name,
        scopes,
      });
      if (!res.ok) return res;
      props.onGenerated(res.data.token, scopes);
      return Ok(null);
    },
  );

  return (
    <FloatingModal
      className={styles.generateTokenModal}
      onRequestClose={props.onRequestClose}
    >
      <ModalSection>
        <Text type="h1">Generate new access token</Text>
      </ModalSection>
      <form {...form.props}>
        <ModalSection>
          {match(form.result)
            .with(null, () => null)
            .with(Ok(P._), () => null)
            .with(Err({ message: P.select() }), (message) => (
              <div className={styles.error}>{message}</div>
            ))
            .exhaustive()}
          <TextInput
            className={styles.nameField}
            label="Name:"
            {...name.props}
          />
          <Text className={styles.scopeTitle}>
            The access token grants access to:
          </Text>
          <ScopeToggle field={scopeCache}>
            <Text>
              The{" "}
              <Link href="/docs/ci/caching/">
                garnix binary cache
              </Link>
            </Text>
          </ScopeToggle>
          <ScopeToggle field={scopeApi}>
            <Text>
              The <Link href="/docs/api">garnix API</Link>
            </Text>
          </ScopeToggle>
        </ModalSection>
        <ModalSection>
          <ModalActions align="right">
            <Button style="secondary" onClick={props.onRequestClose}>
              Cancel
            </Button>
            <Button submit loading={form.loading}>
              Create
            </Button>
          </ModalActions>
        </ModalSection>
      </form>
    </FloatingModal>
  );
};

const ScopeToggle = (props: PropsWithChildren<{ field: Field<boolean> }>) => (
  <div
    className={styles.scopeToggle}
    style={{
      borderColor: props.field.value
        ? "var(--color-stone-900)"
        : "var(--color-stone-300)",
      transition: "border 200ms",
    }}
  >
    <ToggleSwitch className={styles.scopeToggleSwitch} {...props.field.props} />
    {props.children}
  </div>
);

const sampleNetrc = (
  cacheDomain: string,
  username: string,
  accessToken: string,
) =>
  `
machine ${cacheDomain}
  login ${username}
  password ${accessToken}
`.trim();

const nixConfig = endent`
  netrc-file = /etc/nix/netrc
  narinfo-cache-positive-ttl = 3600
`;

const DisplayGeneratedTokenModal = (props: {
  token: string;
  accountTokenScopes: AccountTokenScopes;
  onRequestClose: () => void;
}) => {
  const githubUserName = match(useUser().user)
    .with({ state: "logged-in", user: P.select() }, (user) => user.name)
    .otherwise(
      () =>
        // This should never actually happen since you must be logged in to be
        // on this page, but if for some reason it does happen, at least
        // display something more useful than an error:
        "{YOUR GITHUB USERNAME}",
    );
  // Cache host for the netrc `machine` line, from the backend config (so this
  // isn't hardcoded to garnix.io — a self-host uses its own cache domain).
  const cacheDomain = useConfig().cacheUrl.replace(/^https?:\/\//, "");

  return (
    <FloatingModal
      className={styles.generateTokenModal}
      onRequestClose={props.onRequestClose}
    >
      <ModalSection>
        <Text type="h1">Access token generated</Text>
      </ModalSection>
      <ModalSection>
        <Text type="p">Your generated access token is:</Text>
        <pre className={styles.codeBlock}>{props.token}</pre>
        <Text type="p">
          This token will not be available again after closing this modal.
        </Text>
      </ModalSection>
      {props.accountTokenScopes.cache && (
        <ModalSection>
          <Text type="h3">Binary Cache Access</Text>
          <Text type="p">
            To use this access token to download artifacts from your private
            cache, create a <code className={styles.inlineCode}>netrc</code>{" "}
            file with the following contents:
          </Text>
          <pre className={styles.codeBlock}>
            <SampleCode
              code={sampleNetrc(cacheDomain, githubUserName, props.token)}
              language={"config"}
            />
          </pre>
          <Text type="p">
            then, edit your{" "}
            <code className={styles.inlineCode}>/etc/nix/nix.conf</code> and add
            these lines:
          </Text>
          <pre className={styles.codeBlock}>
            <SampleCode code={nixConfig} language={"config"} />
          </pre>
          <Text type="p">
            The <code className={styles.inlineCode}>netrc-file</code> setting
            needs to point to the{" "}
            <code className={styles.inlineCode}>netrc</code> file you created.
          </Text>
          <Text type="p">
            The{" "}
            <code className={styles.inlineCode}>
              narinfo-cache-positive-ttl
            </code>{" "}
            setting by default is very high (30 days). This has to be lowered,
            since garnix uses presigned urls for private store paths that expire
            much quicker. It should be set to{" "}
            <code className={styles.inlineCode}>3600</code> (i.e. 1 hour).
          </Text>
        </ModalSection>
      )}
      {props.accountTokenScopes.api && (
        <ModalSection>
          <Text type="h3">API Access</Text>
          <Text type="p">
            You can use this access token to access the garnix API, for more
            information see{" "}
            <Link href="/docs/api">our API documentation</Link>
            .
          </Text>
        </ModalSection>
      )}
      <ModalSection>
        <ModalActions align="right">
          <Button style="secondary" onClick={props.onRequestClose}>
            Close
          </Button>
        </ModalActions>
      </ModalSection>
    </FloatingModal>
  );
};
