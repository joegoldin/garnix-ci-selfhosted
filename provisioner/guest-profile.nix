# Shared profile for garnix-deployed microVM guests.
#
# Fixed conventions (the daemon's base guest AND user-deployed
# nixosConfigurations must both use this profile so that
# switch-to-configuration inside the guest keeps a matching fstab):
#   - root volume root.img (20 GiB) mounted at /
#   - host store shared read-only (virtiofs, tag ro-store)
#   - writable store overlay on overlay.img (20 GiB) so nix-copy-closure into
#     the guest works
#   - DHCP on every ethernet (the provisioner's dnsmasq reserves the IP by MAC)
#   - sshd with the hosting public key for root and the garnix user;
#     passwordless sudo for wheel (redeploys run `sudo switch-to-configuration`
#     as the garnix user)
{ lib, config, pkgs, ... }:
let
  cfg = config.garnix.guest;
  statsEnabled = cfg.statsReportUrl != "";
  # Best-effort resource reporter: one /proc read, a short CPU sample, and a
  # single POST. Never fails the guest — a curl error (garnix unreachable) is
  # swallowed so the timer just tries again next tick.
  statsScript = pkgs.writeShellScript "garnix-stats-report" ''
    set -u
    # CPU utilisation from two /proc/stat snapshots ~1s apart.
    s1=$(head -n1 /proc/stat)
    sleep 1
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
    curl -fsS --max-time 10 -H 'Content-Type: application/json' \
      -X POST -d "$payload" "$GARNIX_STATS_URL" >/dev/null 2>&1 || true
  '';
in
{
  options.garnix.guest = {
    sshPublicKey = lib.mkOption {
      type = lib.types.str;
      description = "Hosting SSH public key allowed for root and the garnix user.";
    };
    statsReportUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Full URL of the garnix stats-ingest endpoint (POST /api/hosts/stats).
        When non-empty, a timer POSTs this guest's CPU/RAM sample there every
        ~20s (best-effort). Injected by the provisioner at create time from
        garnix.local-provisioner.statsReportUrl; empty disables the reporter.
      '';
    };
    provisionerId = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = ''
        This guest's provisioner id (the backend's servers.provisioner_id),
        injected by the provisioner. Sent with every stats push so garnix maps
        the sample to the right server row.
      '';
    };
  };
  config = lib.mkMerge [{
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
    networking.useNetworkd = true;
    systemd.network.networks."10-eth" = {
      matchConfig.Type = "ether";
      networkConfig.DHCP = "yes";
    };
    services.openssh.enable = true;
    # Key-only, hardened sshd (no passwords), matching the garnix user-module.
    services.openssh.settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
    # The deploy drops /var/garnix/keys/authorized_keys at RUNTIME when a
    # server opts in via authorizeDeployerGithubKeys / authorizedSSHKeys
    # (copyAuthorizedKeys), so sshd must read it at auth time — scoped to the
    # garnix user only. (authorizedKeys.keyFiles would read it at build time,
    # which both breaks pure eval and can never see the runtime file.) sshd
    # tolerates the file being absent: the garnix user stays login-closed
    # until it exists. Declare your own login users in the guest config for
    # the user-module pattern.
    services.openssh.extraConfig = ''
      Match User garnix
        AuthorizedKeysFile .ssh/authorized_keys /var/garnix/keys/authorized_keys
      Match all
    '';
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
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    # Guests live on a host-only bridge; Traefik fronts them.
    networking.firewall.enable = false;
    system.stateVersion = "25.11";
  }
    # Push-based resource reporter. Guests reach garnix over the public API
    # domain (the same path provisioned guests already use for /api/keys/*):
    # egress NATs out via the host bridge gateway, and Caddy serves the
    # ungated /api/hosts/stats endpoint. Only wired up when the provisioner
    # injected a stats URL.
    (lib.mkIf statsEnabled {
      systemd.services.garnix-stats-reporter = {
        description = "Report guest CPU/RAM to garnix";
        # coreutils (head/sleep/printf), gawk, curl for the sampler + POST.
        path = [ pkgs.coreutils pkgs.gawk pkgs.curl ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = statsScript;
          DynamicUser = true;
          # curl verifies TLS against the guest's system CA bundle.
          Environment = [
            "GARNIX_STATS_URL=${cfg.statsReportUrl}"
            "GARNIX_PROVISIONER_ID=${toString cfg.provisionerId}"
            "CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt"
          ];
        };
      };
      systemd.timers.garnix-stats-reporter = {
        description = "Periodic guest CPU/RAM report to garnix";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "30s";
          OnUnitActiveSec = "20s";
          # Guard against overlap if a report ever runs long.
          AccuracySec = "1s";
        };
      };
    })];
}
