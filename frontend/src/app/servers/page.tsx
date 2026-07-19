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
  redeployServer,
} from "@/services/servers";
import { Table } from "@/components/table";
import { Link } from "@/components/link";
import { diffTime, formatDurationLong, fromSecs } from "@/utils/duration";
import { Text } from "@/components/text";
import { FloatingModal, ModalSection } from "@/components/modal";
import { useForm } from "@/hooks/useForm";
import { AppPage } from "@/utils/appPage";
import { useConfig } from "@/store/configContext";
import styles from "./styles.module.css";
import { ServerFilters, useFilters } from "./filters";
import { DomainsModal } from "./domainsModal";

const statusToColor: Record<RunningServer["status"], string> = {
  Online: "green",
  Failed: "red",
  Booting: "#b4871c",
  Ended: "#999",
};

const Page = () => {
  const { sshHost } = useConfig();
  const serversResult = useLoading(getRunningServers, { poll: fromSecs(5) });
  if (serversResult.loading) return null;
  // Root-relative: both upstream and the self-host docs mirror serve /docs.
  const hostingDocs = "/docs/hosting/introduction";
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
                <Link href={hostingDocs}>Click here</Link> for documentation on
                how to configure deployment on your repo.
              </Text>
            </div>
          ))
          .with(Ok(P.select()), (servers) => (
            <ServersTable
              servers={servers}
              sshHost={sshHost}
              onRequestReload={serversResult.reload}
            />
          ))
          .exhaustive()}
      </div>
    </div>
  );
};

// A copyable one-line shell command (ssh invocation), with a method label.
// Exported for reuse by domainsModal, which shows copyable DNS records with
// the same label + code + copy-button layout.
export const CopyableCommand = ({
  label,
  command,
}: {
  label: string;
  command: string;
}) => {
  const [copied, setCopied] = React.useState(false);
  return (
    <div className={styles.cmdRow}>
      <span className={styles.cmdLabel}>{label}</span>
      <code className={styles.cmd}>{command}</code>
      <button
        type="button"
        className={styles.copyBtn}
        title="Copy to clipboard"
        onClick={() => {
          void navigator.clipboard?.writeText(command);
          setCopied(true);
          window.setTimeout(() => setCopied(false), 1200);
        }}
      >
        {copied ? "Copied" : "Copy"}
      </button>
    </div>
  );
};

// The internal (tailscale/bridge) IP, its own column.
const InternalIpCell = ({ server }: { server: RunningServer }) =>
  server.ipv4 ? (
    <code className={styles.ip}>{server.ipv4}</code>
  ) : (
    <span className={styles.muted}>—</span>
  );

// KiB -> GiB, one decimal (matches the compact table style).
const kbToGiB = (kb: number): string => (kb / 1024 / 1024).toFixed(1);

// Compact CPU% / RAM cell fed by the latest pushed sample.
const ResourcesCell = ({ stats }: { stats: RunningServer["stats"] }) => {
  if (!stats) return <span className={styles.muted}>—</span>;
  const memPct =
    stats.mem_total_kb > 0
      ? Math.round((stats.mem_used_kb / stats.mem_total_kb) * 100)
      : 0;
  return (
    <div className={styles.resources}>
      <span className={styles.resourceLine}>
        <span className={styles.resourceLabel}>CPU</span>
        {stats.cpu_pct.toFixed(1)}%
      </span>
      <span className={styles.resourceLine}>
        <span className={styles.resourceLabel}>RAM</span>
        {kbToGiB(stats.mem_used_kb)} / {kbToGiB(stats.mem_total_kb)} GiB ({memPct}
        %)
      </span>
    </div>
  );
};

// The Connect cell: the SSH methods and any exposed http/tcp ports.
const ConnectCell = ({
  server,
  sshHost,
}: {
  server: RunningServer;
  sshHost: string;
}) => {
  const ip = server.ipv4;
  const sshPort = server.exposed?.ssh_port ?? null;
  const httpPorts = server.exposed?.http ?? [];
  const tcpPorts = server.exposed?.tcp ?? [];
  // The login user garnix authorized; otherwise a placeholder, since the login
  // user is one you declared in the guest config.
  const sshUser = server.exposed?.ssh_user ?? "<user>";
  // <name>.<server-domain>: insert the port name as a subdomain of the URL.
  const portUrl = (name: string) =>
    server.url.replace(/^https:\/\//, `https://${name}.`);
  const hasAny =
    !!ip || (sshPort != null && !!sshHost) || httpPorts.length > 0 || tcpPorts.length > 0;
  return (
    <div className={styles.connect}>
      {hasAny ? (
        <>
          {ip ? (
            <div className={styles.cmdGroup}>
              <CopyableCommand label="Tailscale" command={`ssh ${sshUser}@${ip}`} />
              {sshHost ? (
                <CopyableCommand
                  label="ProxyJump"
                  command={`ssh -J ${sshHost} ${sshUser}@${ip}`}
                />
              ) : null}
              {sshPort != null && sshHost ? (
                <CopyableCommand
                  label="Port-forward"
                  command={`ssh -p ${sshPort} ${sshUser}@${sshHost}`}
                />
              ) : null}
            </div>
          ) : null}
          {httpPorts.length > 0 || tcpPorts.length > 0 ? (
            <div className={styles.portList}>
              {httpPorts.map((p) => (
                <Link key={`h-${p.name}`} href={portUrl(p.name)} className={styles.portChip}>
                  {p.name} ↗
                </Link>
              ))}
              {tcpPorts.map((p) => (
                <span key={`t-${p.name}`} className={styles.portChip}>
                  {p.name} · {sshHost || ip}:{p.host}
                </span>
              ))}
            </div>
          ) : null}
        </>
      ) : (
        <span className={styles.muted}>—</span>
      )}
    </div>
  );
};

// Per-row Redeploy: kicks off a fresh build+deploy job for this server's
// branch/PR and reloads the list. Disabled (spinner) while the request is
// in flight.
const RedeployButton = ({
  serverId,
  onRedeployed,
}: {
  serverId: string;
  onRedeployed: () => void;
}) => {
  const [loading, setLoading] = React.useState(false);
  return (
    <Button
      loading={loading}
      onClick={async () => {
        setLoading(true);
        try {
          await redeployServer(serverId);
          onRedeployed();
        } finally {
          setLoading(false);
        }
      }}
    >
      Redeploy
    </Button>
  );
};

const ServersTable = (props: {
  servers: Array<RunningServer>;
  sshHost: string;
  onRequestReload: () => void;
}) => {
  const filters = useFilters();
  const [currentLogsModal, setCurrentLogsModal] = React.useState<null | string>(
    null,
  );
  const [deleteServerModal, setDeleteServerModal] = React.useState<
    null | string
  >(null);
  const [showDomainsHelp, setShowDomainsHelp] = React.useState(false);
  return (
    <>
      {showDomainsHelp && (
        <DomainsModal onRequestClose={() => setShowDomainsHelp(false)} />
      )}
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
            <th>Resources</th>
            <th>Internal IP</th>
            <th>
              <span className={styles.thConnect}>
                Connect
                <button
                  type="button"
                  className={styles.infoBtn}
                  title="How to point a custom or vanity domain at your hosted servers"
                  aria-label="Custom and vanity domain DNS setup"
                  onClick={() => setShowDomainsHelp(true)}
                >
                  i
                </button>
              </span>
            </th>
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
                <td>
                  <ResourcesCell stats={server.stats} />
                </td>
                <td>
                  <InternalIpCell server={server} />
                </td>
                <td>
                  <ConnectCell server={server} sshHost={props.sshHost} />
                </td>
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
                  <Button href={`/servers/${server.id}`}>Monitor</Button>
                  {server.status !== "Ended" ? (
                    <RedeployButton
                      serverId={server.id}
                      onRedeployed={props.onRequestReload}
                    />
                  ) : null}
                  {server.status === "Online" ? (
                    <Button
                      href={`/servers/${server.id}/terminal`}
                      target="_blank"
                    >
                      Open Terminal
                    </Button>
                  ) : null}
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
