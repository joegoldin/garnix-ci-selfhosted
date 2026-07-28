# Self-host garnix action runner.
#
# garnix runs a repo's `actions` by building the action closure locally and
# then executing it on a separate "action runner": the backend does
# `nix copy --to ssh-ng://action-runner@<GARNIX_ACTION_HOST>` and SSHes in to
# run `action-runner '<command>' '<timeout_secs>'`. Upstream's runner used a
# podman + libkrun/crun microVM stack (and inputs this fork doesn't carry);
# this self-host module instead isolates each action in a bubblewrap +
# slirp4netns sandbox (fresh /home, private NAT'd network, read-only store),
# using only nixpkgs. Point `services.garnixServer.actionHost` at a host
# running this module (typically the garnix box itself, "127.0.0.1").
{ config
, pkgs
, lib
, ...
}:
let
  cfg = config.garnix.actionRunner;

  # `action-runner <command> <timeout_secs>`: run <command> (a /nix/store
  # executable already copied here) in a bubblewrap sandbox with a private
  # slirp4netns network. The action's private key is read from stdin and
  # exposed as GARNIX_ACTION_PRIVATE_KEY_FILE (the backend pipes it in). The
  # repo (when `withRepoContents`) is bind-mounted at /tmp/base via
  # ACTION_REPO_DIR.
  actionRunner = pkgs.writeShellApplication {
    name = "action-runner";
    runtimeInputs = [ pkgs.bubblewrap pkgs.slirp4netns pkgs.coreutils pkgs.getent ];
    text = ''
      TMP=$(mktemp -d)
      # The repo copy (ACTION_REPO_DIR, rsynced in by the backend for
      # withRepoContents) is deleted here because nothing else ever does: the
      # backend creates it over ssh with mktemp -d and forgets it, and an
      # action like a lint run writes gigabytes into it through the /tmp/base
      # bind. Guarded to /tmp so a mangled environment variable cannot aim
      # rm -rf anywhere that matters.
      cleanup() {
        rm -rf "$TMP"
        case "''${ACTION_REPO_DIR:-}" in
          /tmp/?*) rm -rf "$ACTION_REPO_DIR" ;;
        esac
      }
      trap cleanup EXIT

      TEMP_SECRET="$TMP"/secret
      STATUSFILE="$TMP"/bwrap-status
      RESOLVCONF="$TMP"/resolv.conf
      SIGNAL="$TMP"/signalfile
      PASSWDFILE="$TMP"/passwd
      GROUPFILE="$TMP"/group
      HOSTNAMEFILE="$TMP"/hostname

      COMMAND=$1
      TIMEOUT_SECS=$2

      touch "$STATUSFILE"
      getent passwd "$UID" 65534 > "$PASSWDFILE"
      getent group "$(id -g)" 65534 > "$GROUPFILE"

      # The action's private key arrives on stdin.
      cat > "$TEMP_SECRET"
      mkfifo "$SIGNAL"
      # slirp4netns' built-in DNS resolver.
      echo "nameserver 10.0.2.3" > "$RESOLVCONF"
      echo "garnix-action-runner" > "$HOSTNAMEFILE"

      # If the repo was rsynced in (withRepoContents), bind it read-write at
      # /tmp/base and run there; otherwise run from a scratch home.
      REPO_BIND=()
      ACTION_CWD=/home/action-runner
      if [[ -n "''${ACTION_REPO_DIR:-}" && -d "''${ACTION_REPO_DIR:-}" ]]; then
        REPO_BIND=(--bind "$ACTION_REPO_DIR" /tmp/base)
        ACTION_CWD=/tmp/base
      fi

      # For actions that opt into a GitHub token (garnix.yaml `githubToken`), the
      # backend passes an ephemeral, scoped GitHub App token via the GITHUB_TOKEN
      # / NIX_CONFIG env-var prefix. bwrap inherits the environment (we don't
      # --clearenv), but set them explicitly — guarded on non-empty — so the
      # action still sees them if the sandbox ever starts clearing the env.
      TOKEN_ENV=()
      if [[ -n "''${GITHUB_TOKEN:-}" ]]; then
        TOKEN_ENV+=(--setenv GITHUB_TOKEN "$GITHUB_TOKEN")
      fi
      if [[ -n "''${NIX_CONFIG:-}" ]]; then
        TOKEN_ENV+=(--setenv NIX_CONFIG "$NIX_CONFIG")
      fi

      timeout "$TIMEOUT_SECS"s \
        bwrap \
           --unshare-net \
           --unshare-user \
           --unshare-uts \
           `# A PID namespace, so that everything the action starts dies with` \
           `# the sandbox. Without it a daemonized child (the spec suite's` \
           `# postgres, a deploy-spec qemu) outlives the action, keeps the` \
           `# sandbox's mount namespace alive, and pins its tmpfs — multi-GB` \
           `# of shmem per run that nothing ever releases.` \
           --unshare-pid \
           `# The child's host-namespace pid for slirp4netns, which cannot be` \
           `# read from inside any more: $$ in a PID namespace is 1.` \
           --json-status-fd 9 \
           --hostname "garnix-action-runner" \
           --ro-bind /nix /nix \
           --bind /run /run \
           `# NixOS provides /bin/sh + /usr/bin/env as store symlinks; the` \
           `# sandbox execs /bin/sh -c and action shebangs use /usr/bin/env.` \
           --ro-bind /bin/sh /bin/sh \
           --ro-bind-try /usr/bin/env /usr/bin/env \
           --tmpfs /etc \
           --ro-bind-try /etc/hosts /etc/hosts \
           --ro-bind "$HOSTNAMEFILE" /etc/hostname \
           --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf \
           --symlink "$(readlink -f /etc/localtime)" /etc/localtime \
           --ro-bind-try /etc/zoneinfo /etc/zoneinfo \
           --ro-bind-try /etc/ssl /etc/ssl \
           --ro-bind-try /etc/static /etc/static \
           --ro-bind-try /etc/pki /etc/pki \
           --ro-bind-try /etc/protocols /etc/protocols \
           --ro-bind-try /etc/services /etc/services \
           --ro-bind "$RESOLVCONF" /etc/resolv.conf \
           --bind "$PASSWDFILE" /etc/passwd \
           --bind "$GROUPFILE" /etc/group \
           `# The full device-node set upstream bound: actions (e.g. the fork's` \
           `# own test suite) nest garnix's bubblewrap build sandbox, which` \
           `# re-binds these from inside — a missing node (like /dev/zero)` \
           `# fails every nested nix invocation.` \
           --dev-bind-try /dev/console /dev/console \
           --dev-bind-try /dev/core /dev/core \
           --dev-bind-try /dev/full /dev/full \
           --dev-bind-try /dev/null /dev/null \
           `# ptmx must resolve through the bound devpts instance. Binding the` \
           `# host's /dev/ptmx device directly makes allocation fail with` \
           `# ENOENT inside the user namespace.` \
           --dev-bind-try /dev/pts /dev/pts \
           --symlink pts/ptmx /dev/ptmx \
           --dev-bind-try /dev/random /dev/random \
           --dev-bind-try /dev/shm /dev/shm \
           --dev-bind-try /dev/tty /dev/tty \
           --dev-bind-try /dev/urandom /dev/urandom \
           --dev-bind-try /dev/zero /dev/zero \
           --dev-bind-try /dev/net/tun /dev/net/tun \
           --dev-bind-try /dev/kvm /dev/kvm \
           --proc /proc \
           --symlink /proc/self/fd /dev/fd \
           --tmpfs /tmp \
           --die-with-parent \
           --tmpfs /home/action-runner \
           --chdir "$ACTION_CWD" \
           --setenv HOME /home/action-runner \
           `# Deterministic output ordering (ls collation etc.) regardless` \
           `# of the host locale.` \
           --setenv LC_ALL C.UTF-8 \
           --bind "$TEMP_SECRET" "$TEMP_SECRET" \
           --bind "$SIGNAL" /syncfile \
           --setenv GARNIX_ACTION_PRIVATE_KEY_FILE "$TEMP_SECRET" \
           "''${TOKEN_ENV[@]}" \
           "''${REPO_BIND[@]}" \
           /bin/sh -c "read -n 1 -t 30 _ <> /syncfile; $COMMAND" 9> "$STATUSFILE" &

      TIMEOUT_PID=$!

      # bwrap reports the child's pid on the status fd as soon as the sandbox
      # exists. Polling for it also closes the race the old pidfile read had,
      # where slirp4netns could look before the child had written anything.
      CHILD_PID=""
      for _ in $(seq 1 300); do
        CHILD_PID=$(sed -n 's/.*"child-pid": *\([0-9]*\).*/\1/p' "$STATUSFILE" | head -1)
        [[ -n "$CHILD_PID" ]] && break
        sleep 0.1
      done
      if [[ -z "$CHILD_PID" ]]; then
        echo "action-runner: bwrap never reported a child pid" >&2
        kill "$TIMEOUT_PID" 2>/dev/null || true
        exit 1
      fi

      exec {SIGNAL_FD}> "$SIGNAL"

      slirp4netns --configure --mtu=65520 \
          --disable-host-loopback \
          --ready-fd="$SIGNAL_FD" \
          "$CHILD_PID" tap0 2>/dev/null 1>/dev/null &

      SLIRP_PID=$!
      wait "$TIMEOUT_PID"
      kill "$SLIRP_PID" 2>/dev/null || true
    '';
  };

  # SharedResources actions call `bwrap-action-runner`; self-host treats it the
  # same as the default runner (the operator owns all repos).
  bwrapActionRunner = pkgs.runCommand "bwrap-action-runner" { } ''
    mkdir -p "$out/bin"
    ln -s ${actionRunner}/bin/action-runner "$out/bin/bwrap-action-runner"
  '';
in
{
  options.garnix.actionRunner = {
    enable = lib.mkEnableOption "the self-host garnix action runner (bubblewrap-sandboxed)";

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        SSH public keys authorized to log in as the `action-runner` user. This
        must include the public key matching the private key the backend uses
        to reach the runner (`GARNIX_ACTION_RUNNER_SSH_KEY`, default
        /run/secrets/garnix_action_runner_ssh). If you'd rather not paste the
        pubkey, set `sshPrivateKeyPath` instead and it's derived at boot.
      '';
    };

    sshPrivateKeyPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/garnix_action_runner_ssh";
      description = ''
        Path to the action-runner SSH *private* key the backend connects with.
        When set, a boot-time service derives its public key and authorizes it
        for the `action-runner` user — so no separate pubkey secret is needed
        (mirrors the provisioner's hosting-key handling). Combined with
        `authorizedKeys`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ actionRunner bwrapActionRunner ];

    users.users.action-runner = {
      isSystemUser = true;
      shell = pkgs.bash;
      group = "action-runner";
      home = "/home/action-runner";
      createHome = true;
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };
    users.groups.action-runner = { };

    # The backend `nix copy --to ssh-ng://action-runner@...` runs the remote
    # nix-daemon as this user; it must be trusted to import the closure.
    nix.settings.trusted-users = [ config.users.users.action-runner.name ];

    # Derive the authorized pubkey from the backend's action-runner private key
    # at boot (after the secret is installed), so the runner trusts exactly the
    # key the backend connects with — no separate pubkey to manage.
    systemd.services.garnix-action-runner-authorized-key =
      lib.mkIf (cfg.sshPrivateKeyPath != null) {
        description = "Authorize the garnix action-runner SSH key";
        wantedBy = [ "multi-user.target" ];
        before = [ "sshd.service" ];
        # The consumer should order this `after` its secret mechanism (e.g.
        # agenix.service); retry anyway in case the key lands late.
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 3;
        };
        script = ''
          set -eu
          install -d -m 0700 -o action-runner -g action-runner /home/action-runner/.ssh
          umask 077
          ${pkgs.openssh}/bin/ssh-keygen -y -f ${cfg.sshPrivateKeyPath} \
            > /home/action-runner/.ssh/authorized_keys.garnix
          # Merge the derived key with any statically-declared ones (NixOS puts
          # those under /etc/ssh/authorized_keys.d/action-runner, which sshd
          # also reads, so we only own the derived file here).
          install -m 0600 -o action-runner -g action-runner \
            /home/action-runner/.ssh/authorized_keys.garnix \
            /home/action-runner/.ssh/authorized_keys
          rm -f /home/action-runner/.ssh/authorized_keys.garnix
        '';
      };
  };
}
