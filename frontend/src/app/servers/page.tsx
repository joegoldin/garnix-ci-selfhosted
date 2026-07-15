"use client";
import { P, match } from "ts-pattern";
import React from "react";
import { useLoading } from "@/hooks/useLoading";
import { Err, Ok } from "@/services";
import { Button } from "@/components/button";
import {
  RunningServer,
  getRunningServers,
  deleteServer,
} from "@/services/servers";
import { Table } from "@/components/table";
import { Link } from "@/components/link";
import { diffTime, formatDurationLong, fromSecs } from "@/utils/duration";
import { Text } from "@/components/text";
import { FloatingModal, ModalSection } from "@/components/modal";
import { useForm } from "@/hooks/useForm";
import { AppPage } from "@/utils/appPage";
import styles from "./styles.module.css";
import { ServerFilters, useFilters } from "./filters";

const statusToColor: Record<RunningServer["status"], string> = {
  Online: "green",
  Failed: "red",
  Booting: "#b4871c",
  Ended: "#999",
};

const Page = () => {
  const serversResult = useLoading(getRunningServers, { poll: fromSecs(5) });
  if (serversResult.loading) return null;
  return (
    <div className={styles.container}>
      <Text type="h1" className={styles.h1}>
        Servers
      </Text>
      <div className={styles.section}>
        {match(serversResult.data)
          .with(Err(P.select()), (error) => error.message)
          .with(Ok([]), () => (
            <div className={styles.noServers}>
              <Text type="h2">No running servers</Text>
              <Text type="p">You don&apos;t have any running servers.</Text>
              <Text type="p">
                <Link href="/docs/hosting/introduction">Click here</Link>{" "}
                for documentation on how to configure deployment on your repo.
              </Text>
            </div>
          ))
          .with(Ok(P.select()), (servers) => (
            <ServersTable
              servers={servers}
              onRequestReload={serversResult.reload}
            />
          ))
          .exhaustive()}
      </div>
    </div>
  );
};

const ServersTable = (props: {
  servers: Array<RunningServer>;
  onRequestReload: () => void;
}) => {
  const filters = useFilters();
  const [currentLogsModal, setCurrentLogsModal] = React.useState<null | string>(
    null,
  );
  const [deleteServerModal, setDeleteServerModal] = React.useState<
    null | string
  >(null);
  return (
    <>
      {currentLogsModal != null && (
        <FloatingModal onRequestClose={() => setCurrentLogsModal(null)}>
          <ModalSection>
            <Text type="h1">Deploy logs</Text>
            <code className={styles.logs}>{currentLogsModal}</code>
          </ModalSection>
        </FloatingModal>
      )}
      {deleteServerModal != null && (
        <DeleteServerConfirmationModal
          serverId={deleteServerModal}
          onRequestClose={() => setDeleteServerModal(null)}
          onServerDeleted={() => {
            setDeleteServerModal(null);
            props.onRequestReload();
          }}
        />
      )}
      <ServerFilters servers={props.servers} {...filters} />
      <Table>
        <thead>
          <tr>
            <th>Repo</th>
            <th>Deploy Type</th>
            <th>Build</th>
            <th>Status</th>
            <th>IP Address</th>
            <th>Created</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {props.servers.filter(filters.shouldDisplay).map((server) => {
            const repoUrl = `https://github.com/${server.repo_owner}/${server.repo_name}`;
            return (
              <tr key={server.id}>
                <td>
                  <Link href={repoUrl}>
                    {server.repo_owner}/{server.repo_name}
                  </Link>
                </td>
                <td>
                  {match(server.type)
                    .with(
                      { tag: "BranchDeployment", contents: P.select() },
                      (branch) => (
                        <Link href={`${repoUrl}/tree/${branch}`}>
                          Branch {branch}
                        </Link>
                      ),
                    )
                    .with(
                      { tag: "GhPrDeployment", contents: P.select() },
                      (prId) => (
                        <Link href={`${repoUrl}/pull/${prId}`}>PR#{prId}</Link>
                      ),
                    )
                    .exhaustive()}
                </td>
                <td>
                  <Link href={`/build/${server.configuration_build_id}`}>
                    {server.package_name}
                  </Link>
                </td>
                <td
                  className={styles.status}
                  style={{ color: statusToColor[server.status] }}
                >
                  {server.status}
                </td>
                <td>{server.ipv4}</td>
                <td>
                  {server.created_at
                    ? formatDurationLong(
                        diffTime(new Date(), server.created_at),
                      ) + " ago"
                    : "-"}
                </td>
                <td className={styles.rowActions}>
                  {server.status === "Online" ? (
                    <Button
                      onClick={() => {
                        window.open(server.url, "_blank");
                      }}
                    >
                      Visit
                    </Button>
                  ) : null}
                  {server.status !== "Ended" ? (
                    <Button
                      onClick={() => setDeleteServerModal(server.id)}
                      style="warning"
                    >
                      Delete
                    </Button>
                  ) : null}
                  <Button
                    onClick={() => setCurrentLogsModal(server.deploy_logs)}
                  >
                    Logs
                  </Button>
                </td>
              </tr>
            );
          })}
        </tbody>
      </Table>
    </>
  );
};

const DeleteServerConfirmationModal = (props: {
  serverId: string;
  onRequestClose: () => void;
  onServerDeleted: () => void;
}) => {
  const form = useForm({}, async () => {
    await deleteServer(props.serverId);
    props.onServerDeleted();
    return Ok(null);
  });
  return (
    <FloatingModal onRequestClose={props.onRequestClose}>
      <form {...form.props}>
        <ModalSection>
          <Text type="h1">Warning</Text>
          <Text type="p">
            Servers deleted via this web interface will be recreated on each new
            push to the branch. To more reliably delete the server, we recommend
            pushing a commit with the relevant servers entry in garnix.yaml
            removed.
          </Text>
          <Text type="p">
            Are you sure you want to delete this server? This action is
            irreversible.
            {match(form.result)
              .with(Err({ message: P.select() }), (message) => (
                <div className={styles.error}>
                  Failed to delete server:
                  <br />
                  {`${message}`}
                </div>
              ))
              .otherwise(() => null)}
          </Text>
          <div className={styles.actions}>
            <div>
              <Button style="warning" loading={form.loading} submit>
                Yes, delete
              </Button>
              <Button onClick={props.onRequestClose}>Cancel</Button>
            </div>
          </div>
        </ModalSection>
      </form>
    </FloatingModal>
  );
};

export default AppPage(Page, { requireAuth: true });
