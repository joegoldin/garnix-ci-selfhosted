# Durable Terminal CA Handoff Design

## Problem

The provisioner injects the dedicated web-terminal CA public key into the
initial microVM configuration. A repository deployment then activates the
repository-built NixOS configuration. That configuration cannot inherit the
provisioner's host-specific option value, so it either omits the CA file when
using an older guest module or falls back to the hosting/deploy public key when
using the current module. The same activation can also remove the RAM-backed
`/var/garnix/keys` mount when the repository lock is stale.

The dedicated terminal CA must remain trusted after repository activation and
guest reboot. Its private key must remain on erdtree, and a failed public-key
handoff must stop deployment before activating a configuration that cannot
authenticate web-terminal certificates.

## Architecture

Use `/var/lib/garnix/terminal-ca.pub` as the guest's durable public-key handoff
file. Public key material is safe to persist on the guest image; private CA
material remains at `/run/secrets/garnix_terminal_ca` on erdtree.

The guest profile continues to render the provisioner-injected public key at
`/etc/ssh/garnix-hosting-ca.pub` for compatibility and adds a tmpfiles copy
rule that seeds `/var/lib/garnix/terminal-ca.pub` on first boot. OpenSSH trusts
the durable `/var/lib` path. The copy rule does not overwrite an existing
file, allowing the backend to own subsequent refreshes.

Before every new-server activation and persistent-server reactivation, the
backend derives the public key from its configured terminal CA private key and
copies it over the existing hosting-key SSH channel. The destination is
installed as `root:root` mode `0644`. New deployments use the `root` SSH
account; persistent redeployments use the `garnix` account with non-interactive
`sudo`, matching the existing repository-key delivery paths.

## Data Flow

1. The provisioner derives the public terminal CA from erdtree's private key
   and injects it into the initial guest Nix expression.
2. The initial guest profile seeds `/var/lib/garnix/terminal-ca.pub` from its
   generated `/etc` file before sshd starts.
3. The backend derives the same public key immediately before deployment and
   writes it to the durable guest path.
4. Only after that write succeeds does the backend copy and activate the
   repository-built system closure.
5. The activated repository configuration points `TrustedUserCAKeys` at the
   durable file, so activation and later reboots retain the dedicated CA.
6. Re-deployment refreshes the file before activation, allowing CA rotation
   without guest recreation.

## Failure Handling

- Failure to read or derive the configured terminal CA is a deployment error.
- Failure to create the destination directory, write the public key, set
  ownership, or set mode is a deployment error.
- The backend performs the handoff before `switch-to-configuration`; therefore
  a failure leaves the currently active guest configuration untouched.
- Public key content travels on SSH standard input, not in process arguments or
  logs. The private key never leaves erdtree and is never used as a guest login
  identity.
- The first-boot tmpfiles seed is a fallback for provisioned guests. The
  backend refresh is authoritative for deployed guests and CA rotation.

## Testing

Test-driven coverage will establish these contracts:

- A guest-profile evaluation asserts that OpenSSH trusts
  `/var/lib/garnix/terminal-ca.pub` and that tmpfiles seeds it from the injected
  `/etc` public key without overwriting an existing destination.
- Pure deployment-command tests assert direct-root delivery for first deploys
  and `sudo -n` delivery for persistent redeploys.
- Deployment tests assert the terminal CA handoff occurs before closure
  activation and that handoff failure aborts activation.
- Existing backend, provisioner, and Nix package gates remain green.
- Post-deploy runtime verification compares the guest CA with the public key
  derived from erdtree's terminal CA, proves it differs from the hosting key,
  confirms terminal-CA-private root login is denied, and confirms hosting-key
  root login remains available.

## Rollout

1. Commit and push the fork changes after all local gates pass.
2. Update the `garnix-ci` input in dotfiles, verify the erdtree closure builds,
   commit, and push dotfiles.
3. The operator rebuilds erdtree from the pushed dotfiles revision.
4. After the host is verified, update and push `garnix-hello`'s lock so its
   repository-built guest profile includes the durable handoff contract.
5. Verify the resulting fresh deployment against the runtime checklist.

The `garnix-hello` lock must not be pushed before the host runs the backend
that refreshes the durable CA file.
