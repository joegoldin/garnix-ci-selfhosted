# Host-side infrastructure for local microVM hosting (self-host "Hetzner"
# replacement): the garnix-provisionerd daemon (see provisionerd.py) plus the
# network it provisions guests onto — a host-only bridge with dnsmasq DHCP
# (per-MAC reservations) and NAT to the uplink.
#
# The backend talks to the daemon's unix socket when
# services.garnixServer.provisionerSocket is set (LocalProvisioner.hs).
#
# This module deliberately does NOT import microvm.nix (the fork stays
# input-free): the consuming host must itself import
# microvm.nixosModules.host and set `microvm.host.enable = true` so the
# `microvm` CLI and the microvm@ service template exist.
{ config
, lib
, pkgs
, ...
}:
let
  cfg = config.garnix.local-provisioner;
  hostAddr = lib.elemAt (lib.splitString "/" cfg.hostAddress) 0;
  hostPrefixLength = lib.toInt (lib.elemAt (lib.splitString "/" cfg.hostAddress) 1);
  # Guests live in the /24 around the host address (deterministic IPs
  # .10-.249 are derived from the VM id by the daemon).
  subnetPrefix = lib.concatStringsSep "." (lib.take 3 (lib.splitString "." hostAddr));
  stateDir = "/var/lib/garnix-provisioner";
  pubkeyPath = "${stateDir}/hosting.pub";
  # Dedicated web-terminal CA public key (finding H3), derived at service start
  # from cfg.terminalCaPrivateKeyPath and baked into every guest as its
  # TrustedUserCAKeys (NOT the hosting/deploy key).
  terminalCaPubkeyPath = "${stateDir}/terminal-ca.pub";
in
{
  options.garnix.local-provisioner = {
    enable = lib.mkEnableOption "the garnix local microVM provisioner daemon";
    socketPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/garnix-provisioner/provisioner.sock";
      description = ''
        Unix socket the backend connects to (services.garnixServer.provisionerSocket).
        Must live under /run/garnix-provisioner (the service's RuntimeDirectory).
      '';
    };
    bridge = lib.mkOption {
      type = lib.types.str;
      default = "garnixbr0";
      description = "Name of the host-only bridge the guests attach to.";
    };
    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.111.0.1/24";
      description = "The host's CIDR address on the guest bridge (a /24).";
    };
    uplinkInterface = lib.mkOption {
      type = lib.types.str;
      example = "eno1";
      description = "External interface guests NAT out through.";
    };
    sshPrivateKeyPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/garnix_server_ssh_hosting";
      description = ''
        The backend's hosting SSH private key (sshUserHostingKeys). The matching
        public key is derived at service start and baked into every guest.
      '';
    };
    terminalCaPrivateKeyPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/garnix_terminal_ca";
      description = ''
        The dedicated web-terminal certificate-authority private key (finding
        H3), separate from the hosting/deploy key. The matching public key is
        derived at service start and baked into every guest as its
        TrustedUserCAKeys, so the backend's short-lived terminal-session certs
        are trusted WITHOUT the guest trusting the hosting key as a CA. If the
        secret is absent at start the derivation falls back to the hosting
        pubkey so the daemon still starts and guests stay evaluable.
      '';
    };
    guestCpuModel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "IvyBridge";
      description = ''
        QEMU CPU model for guests (microvm.cpu). null (default) keeps
        microvm.nix's `-cpu host` passthrough. A fixed named model narrows
        the host-feature/side-channel surface a guest can see, at the cost
        of hiding newer ISA extensions from guest code. Must be a model the
        host CPU can satisfy (erdtree: dual E5-2667 v2 = IvyBridge;
        IvyBridge-IBRS if the microcode exposes spec-ctrl).
      '';
    };
    nixpkgsFlake = lib.mkOption {
      type = lib.types.str;
      example = "path:/nix/store/...-source";
      description = ''
        Flakeref the per-VM flakes pin nixpkgs to. Pass a store-path ref
        (e.g. "path:''${inputs.nixpkgs}") so guest builds need no network fetch.
      '';
    };
    microvmFlake = lib.mkOption {
      type = lib.types.str;
      example = "path:/nix/store/...-source";
      description = "Flakeref the per-VM flakes pin microvm.nix to (same shape as nixpkgsFlake).";
    };
    backendGroup = lib.mkOption {
      type = lib.types.str;
      default = "garnix";
      description = "Group granted write access to the daemon socket (the backend's group).";
    };
    sshExposePortBase = lib.mkOption {
      type = lib.types.int;
      default = 22000;
      description = ''
        Bottom of the host-port pool for per-VM SSH exposure (garnix.yaml
        sshExpose). Ports are allocated lowest-free from
        [sshExposePortBase, tcpExposePortBase) and recorded per guest.
      '';
    };
    tcpExposePortBase = lib.mkOption {
      type = lib.types.int;
      default = 32000;
      description = ''
        Bottom of the host-port pool for per-VM raw-tcp exposure (garnix.yaml
        ports type=tcp). Ports are allocated lowest-free from
        [tcpExposePortBase, exposePortRange.to] and recorded per guest.
      '';
    };
    exposePortRange = lib.mkOption {
      type = lib.types.submodule {
        options = {
          from = lib.mkOption {
            type = lib.types.port;
            default = 22000;
          };
          to = lib.mkOption {
            type = lib.types.port;
            default = 41999;
          };
        };
      };
      default = {
        from = 22000;
        to = 41999;
      };
      description = ''
        Host TCP port range opened on the uplink for DNAT'd SSH/tcp exposure.
        Must cover both sshExposePortBase (+1000) and tcpExposePortBase (+ 500*20).
      '';
    };
    guestEgressBlocklist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
        "169.254.0.0/16"
        "100.64.0.0/10"
      ];
      example = [
        "10.0.0.0/8"
        "192.168.0.0/16"
        "147.224.12.5/32"
      ];
      description = ''
        Destination CIDRs guests can never initiate connections to (FORWARD
        drop before NAT). The default covers RFC1918 + link-local + CGNAT,
        which includes the guest bridge subnet itself and the host LAN.
        NOTE: setting this option replaces the default — repeat the ranges
        you still want and append internal hosts that are NOT in private
        space (e.g. a remote builder's public address).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    networking = {
      # ── Bridge (scripted networking; no physical ports — guests attach taps) ──
      bridges.${cfg.bridge}.interfaces = [ ];
      interfaces.${cfg.bridge} = {
        useDHCP = false;
        ipv4.addresses = [
          {
            address = hostAddr;
            prefixLength = hostPrefixLength;
          }
        ];
      };
      # If NetworkManager is enabled on the host, keep its hands off the bridge.
      networkmanager.unmanaged = [ "interface-name:${cfg.bridge}" ];

      # ── NAT guest -> internet ─────────────────────────────────────────────────
      nat = {
        enable = true;
        internalInterfaces = [ cfg.bridge ];
        externalInterface = cfg.uplinkInterface;
      };

      firewall = {
        # ── Firewall ──────────────────────────────────────────────────────────────
        # Guests run deployed (potentially untrusted) code, so the bridge is NOT
        # trusted wholesale — that would let a guest reach every host service bound
        # to 0.0.0.0 (postgres, the garnix backend/API, sshd, …) at the host's
        # bridge address, a guest→host pivot. Host→guest still works without
        # trusting the interface: the backend's ssh/nix-copy-closure and Traefik's
        # proxying are host-initiated, so their return traffic is allowed as
        # established/related. Guests only need DHCP inbound to the host (dnsmasq);
        # everything else guest→host is dropped by the default policy. Guest egress
        # to the internet goes through NAT (above), not the host firewall's INPUT.
        interfaces.${cfg.bridge}.allowedUDPPorts = [ 67 ];

        # Open the DNAT exposure range on the uplink. The DNAT itself (added per-VM
        # by the daemon's `expose` action in PREROUTING) rewrites the destination to
        # a guest IP before the routing decision, so these ports reach guests via
        # FORWARD (also opened per-VM) rather than the host — this range opening is
        # belt-and-suspenders for host firewalls that filter the uplink strictly.
        interfaces.${cfg.uplinkInterface}.allowedTCPPortRanges = [
          {
            from = cfg.exposePortRange.from;
            to = cfg.exposePortRange.to;
          }
        ];

        # Isolate guests from one another: drop forwarding between two ports of the
        # guest bridge, so a compromised guest can't reach its neighbours (the pool
        # VM, another tenant's app). Host<->guest is INPUT/OUTPUT (unaffected) and
        # guest->internet is `-i bridge -o uplink` (see the egress ACL below).
        # Primary guest<->guest isolation is bridge PORT ISOLATION (the
        # microvm-tap-interfaces@ hook above); this FORWARD rule and the pinned
        # bridge-nf-call-* sysctls are belt.
        extraCommands = ''
          # delete-then-insert so a reload can't accumulate duplicates
          iptables  -D FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP 2>/dev/null || true
          iptables  -I FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP
          ip6tables -D FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP 2>/dev/null || true
          ip6tables -I FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP 2>/dev/null || true

          # Guest egress ACL (H5): guests may reach the internet but not the LAN,
          # RFC1918/link-local space, or configured internal hosts. Replies to
          # host-/DNAT-initiated inbound connections stay allowed via conntrack
          # (so a LAN client using an exposed DNAT port still gets answers).
          # A dedicated chain, flushed and rebuilt every reload, stays idempotent.
          # Establish a uniquely-commented DROP guard before removing the live jump:
          # if any chain/CIDR command fails, the guard stays and egress fails closed.
          # Reuse a guard left by a prior failed reload instead of duplicating it.
          iptables -C FORWARD -i ${cfg.bridge} -m comment --comment garnix-guest-egress-rebuild -j DROP 2>/dev/null || \
            iptables -I FORWARD 2 -i ${cfg.bridge} -m comment --comment garnix-guest-egress-rebuild -j DROP
          iptables -D FORWARD -i ${cfg.bridge} -j garnix-guest-egress 2>/dev/null || true
          iptables -F garnix-guest-egress 2>/dev/null || true
          iptables -X garnix-guest-egress 2>/dev/null || true
          iptables -N garnix-guest-egress
          iptables -A garnix-guest-egress -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
          ${lib.concatMapStrings (cidr: ''
            iptables -A garnix-guest-egress -d ${cidr} -j DROP
          '') cfg.guestEgressBlocklist}
          iptables -A garnix-guest-egress -j RETURN
          # Position 2: after the bridge<->bridge DROP just inserted at position 1,
          # and ahead of the NAT module's `-i bridge -o uplink -j ACCEPT` (which
          # lives in nixos-filter-forward, appended at the FORWARD tail).
          iptables -I FORWARD 2 -i ${cfg.bridge} -j garnix-guest-egress
          # Only remove the guard after the completed chain is live. If removal
          # fails, the guard remains and guest egress stays fail-closed.
          iptables -D FORWARD -i ${cfg.bridge} -m comment --comment garnix-guest-egress-rebuild -j DROP

          # Guests are IPv4-only (DHCPv4, RA refused): no bridged IPv6 is ever
          # legitimately forwarded, so drop it wholesale instead of mirroring
          # the v4 ACL.
          ip6tables -D FORWARD -i ${cfg.bridge} -j DROP 2>/dev/null || true
          ip6tables -I FORWARD -i ${cfg.bridge} -j DROP 2>/dev/null || true
        '';
        extraStopCommands = ''
          iptables  -D FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP 2>/dev/null || true
          ip6tables -D FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP 2>/dev/null || true
          iptables  -D FORWARD -i ${cfg.bridge} -j garnix-guest-egress 2>/dev/null || true
          iptables  -F garnix-guest-egress 2>/dev/null || true
          iptables  -X garnix-guest-egress 2>/dev/null || true
          iptables  -D FORWARD -i ${cfg.bridge} -m comment --comment garnix-guest-egress-rebuild -j DROP 2>/dev/null || true
          ip6tables -D FORWARD -i ${cfg.bridge} -j DROP 2>/dev/null || true
        '';
      };
    };

    # Pin bridge-nf-call-*: the FORWARD DROP above only sees bridged
    # guest<->guest traffic while br_netfilter routes it through iptables, and
    # this sysctl has been observed flipping 0<->1 at runtime (docker & friends
    # touch it). Pin it ON declaratively. This is belt only — the real
    # guest<->guest barrier is bridge port isolation (the
    # microvm-tap-interfaces@ hook above), which works at L2 regardless.
    boot.kernelModules = [ "br_netfilter" ];
    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
      # M8: never process router advertisements arriving on the guest bridge
      # (a guest could otherwise announce itself as an IPv6 router to the
      # host). systemd's udev rule re-applies per-interface sysctls when the
      # bridge appears, so this survives the interface being created late.
      "net.ipv6.conf.${cfg.bridge}.accept_ra" = 0;
      # M6: the DNAT exposure range (exposePortRange, default 22000-41999)
      # overlaps the kernel's default ephemeral range (32768-60999), so a host
      # outbound connection could occupy a port the daemon DNATs. Move the
      # ephemeral range above the exposed range (defaults: "42000 60999").
      # Tradeoff: ~19000 ephemeral ports instead of ~28000 — ample here.
      "net.ipv4.ip_local_port_range" = "${toString (cfg.exposePortRange.to + 1)} 60999";
    };
    assertions = [
      {
        assertion = cfg.exposePortRange.to < 60000;
        message = "garnix.local-provisioner.exposePortRange.to must stay below 60000 so an ephemeral port range remains above it.";
      }
    ];

    # ── Guest<->guest isolation at L2 (bridge port isolation) ─────────────────
    # Guest specs use `type = "tap"` interfaces named gx<id>. microvm.nix's
    # microvm-tap-interfaces@<vm> template creates the tap but attaches it to
    # nothing; this ExecStartPost drop-in enslaves it to the guest bridge as an
    # ISOLATED port. Isolated ports may talk to the bridge device itself (host:
    # dnsmasq DHCP, Traefik, backend ssh, NAT) but never to another isolated
    # port — killing guest->guest unicast, ARP/ND spoofing and rogue RA/DHCP at
    # L2, independent of the bridge-nf-call-* sysctls. Ordering is race-free:
    # microvm@%i is After= this oneshot, which only completes once
    # ExecStartPost has run. Non-garnix microVMs on the host are untouched.
    systemd = {
      services."microvm-tap-interfaces@".serviceConfig.ExecStartPost = [
        "${pkgs.writeShellScript "garnix-tap-isolate" ''
          set -euo pipefail
          case "$1" in
            garnix-*) ;;
            *) exit 0 ;;
          esac
          tap="gx''${1#garnix-}"
          ${pkgs.iproute2}/bin/ip link set dev "$tap" master ${cfg.bridge}
          ${pkgs.iproute2}/bin/ip link set dev "$tap" type bridge_slave isolated on
        ''} %i"
      ];

      # ── State ─────────────────────────────────────────────────────────────────
      tmpfiles.rules = [
        "d ${stateDir} 0755 root root -"
        "d ${stateDir}/specs 0755 root root -"
        "d ${stateDir}/exposed 0755 root root -"
        "f ${stateDir}/dnsmasq-hosts 0644 root root -"
      ];

      # ── The daemon ────────────────────────────────────────────────────────────
      services.garnix-provisionerd = {
        description = "garnix local microVM provisioner";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network.target"
          "dnsmasq.service"
        ];
        # `microvm` and `systemctl` come from the running system profile; nix and
        # ssh-keygen are pinned so the daemon works even before the first switch.
        path = [
          pkgs.nix
          pkgs.openssh
          pkgs.iptables
          "/run/current-system/sw"
        ];
        environment = {
          PROVISIONER_SOCKET = cfg.socketPath;
          PROVISIONER_SOCKET_GROUP = cfg.backendGroup;
          PROVISIONER_STATE_DIR = stateDir;
          PROVISIONER_BRIDGE = cfg.bridge;
          PROVISIONER_SUBNET_PREFIX = subnetPrefix;
          PROVISIONER_NIXPKGS = cfg.nixpkgsFlake;
          PROVISIONER_MICROVM = cfg.microvmFlake;
          PROVISIONER_GUEST_PROFILE = "${./guest-profile.nix}";
          PROVISIONER_SSH_PUBKEY_FILE = pubkeyPath;
          PROVISIONER_TERMINAL_CA_PUBKEY_FILE = terminalCaPubkeyPath;
          PROVISIONER_PORT_RANGE_END = toString cfg.exposePortRange.to;
          PROVISIONER_GUEST_CPU = if cfg.guestCpuModel == null then "" else cfg.guestCpuModel;
          PROVISIONER_UPLINK = cfg.uplinkInterface;
          PROVISIONER_SSH_PORT_BASE = toString cfg.sshExposePortBase;
          PROVISIONER_TCP_PORT_BASE = toString cfg.tcpExposePortBase;
        };
        serviceConfig = {
          ExecStartPre = pkgs.writeShellScript "garnix-provisioner-pubkey" ''
            set -euo pipefail
            ${pkgs.openssh}/bin/ssh-keygen -y -f ${cfg.sshPrivateKeyPath} > ${pubkeyPath}
            chmod 0644 ${pubkeyPath}
            # Dedicated web-terminal CA public key (finding H3): guests trust THIS
            # as TrustedUserCAKeys, not the hosting key. Fall back to the hosting
            # pubkey if the terminal-CA secret isn't installed, so the daemon still
            # starts and guests stay evaluable (the Python side mirrors this).
            if ${pkgs.openssh}/bin/ssh-keygen -y -f ${cfg.terminalCaPrivateKeyPath} > ${terminalCaPubkeyPath} 2>/dev/null; then
              :
            else
              cp ${pubkeyPath} ${terminalCaPubkeyPath}
            fi
            chmod 0644 ${terminalCaPubkeyPath}
          '';
          ExecStart = "${pkgs.python3}/bin/python3 ${./provisionerd.py}";
          RuntimeDirectory = "garnix-provisioner";
          Restart = "always";
          RestartSec = 5;
        };
        unitConfig.StartLimitIntervalSec = 0;
      };
    };

    # ── dnsmasq: DHCP-only, per-MAC reservations from the daemon ─────────────
    services.dnsmasq = {
      enable = true;
      # This dnsmasq only serves DHCP on the guest bridge; never make it the
      # host's resolver.
      resolveLocalQueries = false;
      settings = {
        port = 0; # DHCP only, no DNS
        interface = cfg.bridge;
        bind-interfaces = true;
        dhcp-range = "${subnetPrefix}.10,${subnetPrefix}.250,12h";
        dhcp-hostsfile = "${stateDir}/dnsmasq-hosts";
        dhcp-option = [
          "option:router,${hostAddr}"
          "option:dns-server,9.9.9.9"
        ];
      };
    };
  };
}
