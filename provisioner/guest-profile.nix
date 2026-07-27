# Shared profile for garnix-deployed microVM guests.
#
# Fixed conventions (the daemon's base guest AND user-deployed
# nixosConfigurations must both use this profile so that
# switch-to-configuration inside the guest keeps a matching fstab):
#   - root volume root.img (20 GiB) mounted at /
#   - host store shared read-only (virtiofs, tag ro-store)
#   - writable store overlay on overlay.img (20 GiB) so nix-copy-closure into
#     the guest works
#   - /var/garnix/keys on tmpfs (deploy-delivered keys are RAM-only, never
#     at rest on the disk images)
#   - DHCP on every ethernet (the provisioner's dnsmasq reserves the IP by MAC)
#   - sshd with the hosting public key for root and the garnix user;
#     passwordless sudo for wheel (redeploys run `sudo switch-to-configuration`
#     as the garnix user)
#
# `garnix.server.*` also carries the post-eval description of this config as
# a deployable server (mirrors garnix.yaml's legacy `servers:` list, but
# discovered by the backend via `nix eval` after the build instead of parsed
# pre-eval — see docs/plans/2026-07-27-nix-native-server-config-design.md).
# Example:
#   garnix.server = {
#     deployment = { type = "on-branch"; branch = "main"; machine = "i1x2"; };
#     domains = [ "app.example.com" ];
#     backups.paths = [ "/var/lib/myapp" ];
#   };
# The full aggregate (JSON-serializable, `deployment = null` when unset) is
# always rendered to /etc/garnix/server.json in the guest, which is also
# what closure-pins any `${pkgs.foo}/bin/bar` referenced by a backup hook.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.garnix.server;

  # Mirrors backend/src/Garnix/YamlConfig.hs's parseBackupSchedule /
  # validateBackupPath, so a nix-declared server fails the same assertions a
  # garnix.yaml-declared one would fail at config-parse time.
  isBackupScheduleValid =
    s:
    s == "hourly"
    || s == "daily"
    || s == "weekly"
    || (
      let
        m = builtins.match "([0-9]+)h" s;
      in
      m != null && lib.toInt (builtins.head m) >= 1
    );
  backupPathIsAbsolute = p: lib.hasPrefix "/" p;
  backupPathUnderNixStore = p: lib.hasPrefix "/nix/store" p;
  backupPathHasDotDot = p: lib.elem ".." (lib.splitString "/" p);

  # Resource reporter: one /proc read, a short CPU sample, and a POST (with a
  # few retries for transient blips). Unlike the old best-effort version, a
  # persistent failure is SURFACED rather than swallowed: curl's error goes to
  # the journal and the unit exits non-zero, so `systemctl status
  # garnix-stats-reporter` / `journalctl -u garnix-stats-reporter` reveal a
  # wedged reporter (lost egress, or a 404 for an ended/orphaned server row).
  # The timer still re-arms every tick regardless of the exit code.
  statsScript = pkgs.writeShellScript "garnix-stats-report" ''
    set -u
    # CPU utilisation from two /proc/stat snapshots ~1s apart.
    s1=$(head -n1 /proc/stat)
    sleep "''${GARNIX_STATS_CPU_SAMPLE_DELAY:-1}"
    s2=$(head -n1 /proc/stat)
    cpu=$(awk -v a="$s1" -v b="$s2" 'BEGIN {
      na = split(a, x, " "); nb = split(b, y, " ");
      # x[1]="cpu"; x[2..] = user nice system idle iowait irq softirq steal ...
      t1 = 0; for (i = 2; i <= na; i++) t1 += x[i];
      t2 = 0; for (i = 2; i <= nb; i++) t2 += y[i];
      idle1 = x[5] + x[6]; idle2 = y[5] + y[6];   # idle + iowait
      dt = t2 - t1; di = idle2 - idle1;
      if (dt <= 0) printf "0.0"; else printf "%.1f", (1 - di / dt) * 100;
    }')
    memtotal=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
    memavail=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
    memused=$((memtotal - memavail))
    payload=$(printf '{"provisioner_id":%d,"cpu_pct":%s,"mem_used_kb":%d,"mem_total_kb":%d}' \
      "$GARNIX_PROVISIONER_ID" "$cpu" "$memused" "$memtotal")
    # Accept exactly 2xx. curl's --fail only rejects 4xx/5xx, so relying on it
    # would treat an Authentik 302 as a successful report even though no sample
    # reached garnix. Retry a couple of transient failures before giving up; a
    # final failure exits non-zero (visible in the unit state).
    attempt=1
    while :; do
      if status=$(curl -sS --max-time 10 --output /dev/null \
           --write-out '%{http_code}' -H 'Content-Type: application/json' \
           -X POST -d "$payload" "$GARNIX_STATS_URL"); then
        case "$status" in
          2??) exit 0 ;;
          *) echo "garnix-stats-report: unexpected HTTP status $status" >&2 ;;
        esac
      fi
      if [ "$attempt" -ge 3 ]; then
        echo "garnix-stats-report: POST to garnix failed after $attempt attempts" >&2
        exit 1
      fi
      attempt=$((attempt + 1))
      sleep "''${GARNIX_STATS_RETRY_DELAY:-3}"
    done
  '';
in
{
  options.garnix.guest = {
    sshPublicKey = lib.mkOption {
      type = lib.types.str;
      default = lib.removeSuffix "\n" (builtins.readFile ./hosting-public-key.pub);
      defaultText = lib.literalExpression "builtins.readFile ./hosting-public-key.pub";
      description = ''
        Hosting SSH public key allowed for root and the garnix user.

        WARNING: the default is not a placeholder. It's the actual hosting
        public key for this fork's own running instance, checked into
        ./hosting-public-key.pub in this repo — which is PUBLIC. It stays the
        default deliberately, for that instance's own dotfiles/deployment
        convenience; this module intentionally does not assert it away.

        Any OTHER operator consuming `nixosModules.garnix-guest` MUST override
        BOTH this option and `garnix.guest.terminalCaPublicKey` with their own
        provisioner's hosting public key (read it from
        `/var/lib/garnix-provisioner/hosting.pub` on your host). If you don't:
          - every guest you deploy will authorize a stranger's key (this
            fork's own) to log in as root and as the garnix user, instead of
            yours;
          - your own backend has no matching private key, so it can never
            reach the guests it deploys — deploys, redeploys, and the web
            terminal will all fail to authenticate.
      '';
    };
    terminalCaPublicKey = lib.mkOption {
      type = lib.types.str;
      default = config.garnix.guest.sshPublicKey;
      description = ''
        Public key of the dedicated web-terminal certificate authority (finding
        H3), trusted as TrustedUserCAKeys so the backend can mint short-lived
        per-session login certs WITHOUT the guest trusting the hosting/deploy
        key as a CA. Defaults to sshPublicKey for backward compatibility: guests
        deployed before H3 (and user flakes that don't set it) keep trusting the
        hosting key as CA. The provisioner injects the real terminal-CA pubkey.
      '';
    };
  };

  options.garnix.server = {
    deployment = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            type = lib.mkOption {
              type = lib.types.enum [
                "on-branch"
                "on-pull-request"
              ];
              description = "When to deploy: on every push to `branch`, or on every pull request.";
            };
            branch = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = ''
                Git branch to deploy from. Relevant only when `type =
                "on-branch"`; leave at the default for `"on-pull-request"`.
              '';
            };
            machine = lib.mkOption {
              type = lib.types.str;
              default = "i1x2";
              description = ''
                MicroVM tier to provision (e.g. "i1x1", "i1x2", "i2x2", ...).
                Tier is a provisioning-time decision: changing it on an
                already-deployed PERSISTENT server (garnix.server.persistence.enable
                = true) requires recreating the VM — an in-place redeploy cannot
                resize an existing guest's disks/CPU/RAM allocation.
              '';
            };
            isPrimary = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "If this deploy should also be reachable at «repo-name».«org-name».garnix.me.";
            };
          };
        }
      );
      default = null;
      description = ''
        When/how this configuration gets deployed as a server. `null` (the
        default) means this buildable configuration is never deployed — the
        same as not declaring a server for it at all.
      '';
    };

    domains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra hostnames (full FQDNs) this server should also answer on.";
    };

    exposeSSH = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open a public DNAT port on the garnix host forwarding to the guest's SSH (:22).";
    };

    authorizeDeployerGithubKeys = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Authorize the deployer's github.com/<user>.keys to log in as the garnix user on the deployed server.";
    };

    authorizedSSHKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra SSH public keys to authorize for login as the garnix user on the deployed server.";
    };

    ports = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "A short name; used as the subdomain (http) or label (tcp).";
            };
            port = lib.mkOption {
              type = lib.types.port;
              description = "The port the service listens on inside the server.";
            };
            type = lib.mkOption {
              type = lib.types.enum [
                "http"
                "tcp"
              ];
              default = "http";
              description = ''"http" (default) exposes <name>.<server-domain>; "tcp" exposes a raw host:port.'';
            };
          };
        }
      );
      default = [ ];
      description = "Extra ports to expose, beyond the standard :80.";
    };

    applicationLog = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Stream the configured application log in the Servers-page Logs modal.";
            };
            path = lib.mkOption {
              type = lib.types.str;
              default = "/var/log/nginx/hello-access.log";
              description = "Absolute guest path to follow when application logging is enabled.";
            };
          };
        }
      );
      default = null;
      description = "Optional application-log stream. `null` (the default) means no log follows this server.";
    };

    backups = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            paths = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                Absolute paths inside the server to back up. Must be
                non-empty when `backups` is set, and none may be "/" or
                under /nix/store.
              '';
            };
            schedule = lib.mkOption {
              type = lib.types.str;
              default = "daily";
              description = ''How often to back up: "hourly" | "daily" (default) | "weekly" | "<N>h" (N >= 1).'';
            };
            preBackupCommand = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Command run on the server (as root, via sh -c) before the backup tar is taken. A non-zero exit aborts the backup.";
            };
            postBackupCommand = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Command run on the server after the tar is taken (cleanup). Always attempted, even if the tar failed.";
            };
            preRestoreCommand = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Command run on the server before a restore untars (e.g. stop your service).";
            };
            postRestoreCommand = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Command run on the server after a restore untars (e.g. start your service). Always attempted, even if the untar failed.";
            };
          };
        }
      );
      default = null;
      description = "Scheduled backups of paths on this server. `null` (the default) means no backups.";
    };

    deploySpec = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default =
        let
          persistenceEnabled = cfg.persistence.enable or false;
        in
        {
          deployment =
            if cfg.deployment == null then
              null
            else
              {
                inherit (cfg.deployment)
                  type
                  branch
                  machine
                  isPrimary
                  ;
              };
          inherit (cfg)
            domains
            exposeSSH
            authorizeDeployerGithubKeys
            authorizedSSHKeys
            ;
          ports = map (p: { inherit (p) name port type; }) cfg.ports;
          applicationLog =
            if cfg.applicationLog == null then null else { inherit (cfg.applicationLog) enable path; };
          backups =
            if cfg.backups == null then
              null
            else
              {
                inherit (cfg.backups)
                  paths
                  schedule
                  preBackupCommand
                  postBackupCommand
                  preRestoreCommand
                  postRestoreCommand
                  ;
              };
          persistence = {
            enable = persistenceEnabled;
            # Only forced when enabled: garnix-lib's `persistence.name` has no
            # default, so forcing it while disabled (or while the garnix-lib
            # module isn't imported at all) would throw instead of falling
            # back — this keeps configs WITHOUT garnix-lib imported evaluable.
            name = if persistenceEnabled then cfg.persistence.name else null;
          };
        };
      description = ''
        Read-only, JSON-serializable aggregate of every `garnix.server.*`
        option above (plus `garnix.server.persistence`, when garnix-lib's
        module is also imported). Rendered verbatim to
        `/etc/garnix/server.json` in the guest below — the backend `nix
        eval`s this one option per built `nixosConfiguration` to discover
        servers declared in Nix instead of garnix.yaml's legacy `servers:`
        list.
      '';
    };
  };

  config = lib.mkMerge [
    {
      assertions =
        lib.optionals (cfg.backups != null) [
          {
            assertion = cfg.backups.paths != [ ];
            message = "garnix.server.backups.paths must not be empty when garnix.server.backups is set.";
          }
          {
            assertion = isBackupScheduleValid cfg.backups.schedule;
            message = ''garnix.server.backups.schedule must be "hourly", "daily", "weekly", or "<N>h" (N >= 1); got: "${cfg.backups.schedule}"'';
          }
          {
            assertion = lib.all backupPathIsAbsolute cfg.backups.paths;
            message = "garnix.server.backups.paths entries must be absolute paths.";
          }
          {
            assertion = !(lib.elem "/" cfg.backups.paths);
            message = ''garnix.server.backups.paths must not contain "/".'';
          }
          {
            assertion = !(lib.any backupPathUnderNixStore cfg.backups.paths);
            message = "garnix.server.backups.paths must not contain /nix/store paths.";
          }
          {
            assertion = !(lib.any backupPathHasDotDot cfg.backups.paths);
            message = ''garnix.server.backups.paths must not contain ".." components.'';
          }
        ]
        ++ [
          {
            assertion = lib.all (d: d != "") cfg.domains;
            message = "garnix.server.domains entries must be non-empty strings.";
          }
        ];

      # Load-bearing for hook store-path pinning (backups.preBackupCommand
      # etc. may reference ${pkgs.foo}/bin/bar): rendering the aggregate as a
      # derivation-context string is what puts every referenced store path
      # into this system closure, which is what the deploy actually copies
      # to the guest. `nix eval`ing garnix.server.deploySpec directly (as the
      # backend also does, read-only, for discovery) would NOT pin anything
      # by itself. Unconditional — harmless for configs that aren't servers
      # (deploySpec.deployment is just `null`).
      environment.etc."garnix/server.json".text = builtins.toJSON cfg.deploySpec;

      microvm = {
        hypervisor = "qemu";
        volumes = [
          {
            image = "root.img";
            mountPoint = "/";
            size = 20 * 1024;
          }
          {
            image = "overlay.img";
            mountPoint = "/nix/.rw-store";
            size = 20 * 1024;
          }
        ];
        shares = [
          {
            source = "/nix/store";
            mountPoint = "/nix/.ro-store";
            tag = "ro-store";
            proto = "virtiofs";
          }
        ];
        writableStoreOverlay = "/nix/.rw-store";
      };
      # Deploy-delivered key material (repo-key, default-authentik.env,
      # authorized_keys) lives in RAM only: a tmpfs over /var/garnix/keys means
      # the repo's secret-decryption key is never written to the persistent
      # root.img, so a copied/backed-up/leaked disk image can't yield it (M1).
      # The backend delivers all three files post-boot over ssh (copyKeys /
      # copyDefaultAuthentikEnv / copyAuthorizedKeys), so the mount — active
      # since local-fs.target, long before sshd — is always in place first.
      # mode=0755 (not 0700) because sshd opens
      # /var/garnix/keys/authorized_keys with the garnix user's uid, so the
      # directory must stay world-traversable; the secrets themselves remain
      # root-only via their file modes (repo-key 0400). Guests configure no
      # swap, so the pages can't be written out.
      fileSystems."/var/garnix/keys" = {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [
          "mode=0755"
          "size=4m"
        ];
      };
      networking.useNetworkd = true;
      systemd = {
        network.networks."10-eth" = {
          matchConfig.Type = "ether";
          # IPv4-only: the provisioner's dnsmasq (per-MAC reservations) is the
          # single source of addressing truth. Never accept router advertisements
          # — on a shared bridge an RA is how a neighbour impersonates the
          # gateway (M8). Host-side bridge port isolation already stops
          # guest->guest RA/DHCP at L2; this is guest-side belt.
          networkConfig = {
            DHCP = "ipv4";
            IPv6AcceptRA = false;
          };
        };
        # The provisioner-specific first boot renders the dedicated terminal CA
        # above. Seed a durable public copy once so a repository-built NixOS
        # configuration can trust the same CA after activation and reboot. The
        # backend refreshes this file before every activation, including rotation;
        # `C` deliberately leaves an existing authoritative copy untouched.
        tmpfiles.rules = [
          "d /var/lib/garnix 0755 root root - -"
          "C /var/lib/garnix/terminal-ca.pub 0644 root root - /etc/ssh/garnix-hosting-ca.pub"
        ];
        # Keep the reporter installed in repository-built configurations too.
        # The backend creates the durable, public URL/id file after it claims a
        # pre-warm guest and before repository activation. ConditionPathExists
        # keeps an unclaimed pool guest inert while preserving the same reporter
        # across activation and reboot.
        services.garnix-stats-reporter = {
          description = "Report guest CPU/RAM to garnix";
          unitConfig.ConditionPathExists = "/var/lib/garnix/stats.env";
          # coreutils (head/sleep/printf), gawk, curl for the sampler + POST.
          path = [
            pkgs.coreutils
            pkgs.gawk
            pkgs.curl
          ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = statsScript;
            DynamicUser = true;
            EnvironmentFile = "/var/lib/garnix/stats.env";
            # curl verifies TLS against the guest's system CA bundle.
            Environment = [
              "CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt"
            ];
          };
        };
        timers.garnix-stats-reporter = {
          description = "Periodic guest CPU/RAM report to garnix";
          unitConfig.ConditionPathExists = "/var/lib/garnix/stats.env";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "30s";
            OnUnitActiveSec = "20s";
            # Guard against overlap if a report ever runs long.
            AccuracySec = "1s";
          };
        };
      };
      boot.kernel.sysctl = {
        "net.ipv6.conf.all.accept_ra" = 0;
        "net.ipv6.conf.default.accept_ra" = 0;
      };
      environment.etc."ssh/garnix-hosting-ca.pub".text = config.garnix.guest.terminalCaPublicKey + "\n";
      services.openssh = {
        enable = true;
        # Key-only, hardened sshd (no passwords), matching the garnix user-module.
        settings = {
          PermitRootLogin = "prohibit-password";
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
        };
        # The NixOS-managed key file always carries the standing hosting key the
        # backend needs for deploys and post-activation account discovery. The
        # deploy additionally drops /var/garnix/keys/authorized_keys at RUNTIME
        # when a server opts into deployer/explicit human keys, so sshd must read
        # both paths at auth time — scoped to the garnix user only.
        # (authorizedKeys.keyFiles would read the runtime path at build time,
        # which both breaks pure eval and can never see the delivered file.)
        # Declare your own login users in the guest config for the user-module
        # pattern.
        # Trust the DEDICATED web-terminal certificate authority (finding H3) as a
        # user-certificate authority — NOT the hosting/deploy key. This lets the
        # backend mint short-lived, per-session SSH certificates (signed by the
        # terminal CA) to open the web terminal directly as any declared login user
        # (e.g. `joe`), while the hosting key stays purely a deploy/login identity.
        # Splitting the CA from the hosting key means a terminal-CA compromise can
        # only mint terminal certs (bounded by the login-user principal the backend
        # sets), and does NOT hand out the standing root/deploy key. The certs are
        # minted on demand by the backend and expire within the terminal-session
        # window. The /etc file keeps its historical name and seeds the durable
        # copy on first boot. terminalCaPublicKey defaults to the hosting key, so
        # guests deployed before H3 stay evaluable until recreated.
        #
        # AuthorizedPrincipalsFile pins a terminal cert to THIS server, not just
        # to its login user. Every terminal cert is signed (see
        # Garnix.API.Terminal's signingArgs) with TWO principals:
        # `<loginUser>,server-<serverHash>`. Absent this directive, sshd falls
        # back to its default certificate check — the cert must carry a
        # principal equal to the local username — which is per-USER but not
        # per-SERVER: a cert minted for server A would also authenticate a
        # same-named user on server B. Setting AuthorizedPrincipalsFile REPLACES
        # that default check with "the cert must carry a principal listed in
        # this file". The backend (Garnix.Hosting.Deploy's
        # copyTerminalPrincipals, called wherever copyTerminalCa is) delivers a
        # file here containing exactly one line, `server-<serverHash>`, computed
        # the same way as the cert's own principal — so a cert minted for a
        # different server lacks this server's principal and is rejected here,
        # giving per-SERVER pinning. Per-USER enforcement still holds, just
        # upstream: the backend's requireDeclaredLoginUser only ever mints a
        # cert for a login user the guest actually declares (never root), so
        # deliberately do NOT also list usernames in this file — it wouldn't add
        # per-user enforcement and only complicates delivery. Guests running an
        # older profile (neither this directive nor the file) keep the sshd
        # default of per-user-only pinning until redeployed onto this profile.
        extraConfig = ''
          TrustedUserCAKeys /var/lib/garnix/terminal-ca.pub
          AuthorizedPrincipalsFile /var/lib/garnix/terminal-principals
          Match User garnix
            AuthorizedKeysFile %h/.ssh/authorized_keys /etc/ssh/authorized_keys.d/%u /var/garnix/keys/authorized_keys
          Match all
        '';
      };
      users.users.root.openssh.authorizedKeys.keys = [ config.garnix.guest.sshPublicKey ];
      users.users.garnix = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        # The hosting key (for backend redeploys) is always authorized.
        openssh.authorizedKeys.keys = [ config.garnix.guest.sshPublicKey ];
      };
      security.sudo.wheelNeedsPassword = false;
      # Enable flakes + the new nix CLI so `nix build`/`nix run`/`nix shell` and
      # flake-based tooling work when you SSH into a deployed guest.
      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];
      # Guests live on a host-only bridge, but they run deployed (semi-trusted)
      # code next to neighbours — keep the firewall ON as containment hygiene.
      # 22 is the deploy/sshExpose path; 80 is the common Traefik http target
      # (the hello example). Deployed configs that serve on other ports
      # (garnix.yaml servers[].ports) must open them themselves — the standard
      # option merges with this one:
      #   networking.firewall.allowedTCPPorts = [ 3000 ];
      # mkDefault so a guest config can still opt out explicitly.
      networking.firewall = {
        enable = lib.mkDefault true;
        allowedTCPPorts = [
          22
          80
        ];
      };
      system.stateVersion = "25.11";
    }
    (lib.mkIf config.services.nginx.enable {
      # nginx's LogsDirectory is created/chowned when nginx starts. During a
      # first activation, logrotate-checkconf otherwise races that preparation
      # and its `su nginx nginx` rule cannot traverse /var/log/nginx.
      systemd.services.logrotate-checkconf.after = [ "nginx.service" ];
    })
  ];
}
