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
{ config, lib, pkgs, ... }:
let
  cfg = config.garnix.local-provisioner;
  hostAddr = lib.elemAt (lib.splitString "/" cfg.hostAddress) 0;
  hostPrefixLength = lib.toInt (lib.elemAt (lib.splitString "/" cfg.hostAddress) 1);
  # Guests live in the /24 around the host address (deterministic IPs
  # .10-.249 are derived from the VM id by the daemon).
  subnetPrefix = lib.concatStringsSep "." (lib.take 3 (lib.splitString "." hostAddr));
  stateDir = "/var/lib/garnix-provisioner";
  pubkeyPath = "${stateDir}/hosting.pub";
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
        Base host port for per-VM SSH exposure (garnix.yaml sshExpose). A guest
        with id N is reachable at sshExposePortBase + (N mod 1000).
      '';
    };
    tcpExposePortBase = lib.mkOption {
      type = lib.types.int;
      default = 32000;
      description = ''
        Base host port for per-VM raw-tcp exposure (garnix.yaml ports type=tcp).
        Each VM gets a contiguous block of 20 host ports.
      '';
    };
    exposePortRange = lib.mkOption {
      type = lib.types.submodule {
        options = {
          from = lib.mkOption { type = lib.types.port; default = 22000; };
          to = lib.mkOption { type = lib.types.port; default = 41999; };
        };
      };
      default = { from = 22000; to = 41999; };
      description = ''
        Host TCP port range opened on the uplink for DNAT'd SSH/tcp exposure.
        Must cover both sshExposePortBase (+1000) and tcpExposePortBase (+ 500*20).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # ── Bridge (scripted networking; no physical ports — guests attach taps) ──
    networking.bridges.${cfg.bridge}.interfaces = [ ];
    networking.interfaces.${cfg.bridge} = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = hostAddr;
          prefixLength = hostPrefixLength;
        }
      ];
    };
    # If NetworkManager is enabled on the host, keep its hands off the bridge.
    networking.networkmanager.unmanaged = [ "interface-name:${cfg.bridge}" ];

    # ── NAT guest -> internet ─────────────────────────────────────────────────
    networking.nat = {
      enable = true;
      internalInterfaces = [ cfg.bridge ];
      externalInterface = cfg.uplinkInterface;
    };

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
    networking.firewall.interfaces.${cfg.bridge}.allowedUDPPorts = [ 67 ];

    # Open the DNAT exposure range on the uplink. The DNAT itself (added per-VM
    # by the daemon's `expose` action in PREROUTING) rewrites the destination to
    # a guest IP before the routing decision, so these ports reach guests via
    # FORWARD (also opened per-VM) rather than the host — this range opening is
    # belt-and-suspenders for host firewalls that filter the uplink strictly.
    networking.firewall.interfaces.${cfg.uplinkInterface}.allowedTCPPortRanges = [
      { from = cfg.exposePortRange.from; to = cfg.exposePortRange.to; }
    ];

    # Isolate guests from one another: drop forwarding between two ports of the
    # guest bridge, so a compromised guest can't reach its neighbours (the pool
    # VM, another tenant's app). Host<->guest is INPUT/OUTPUT (unaffected) and
    # guest->internet is `-i bridge -o uplink` (unaffected). Inserted at the head
    # of FORWARD so it wins over the ACCEPT policy and the NAT accept rules. This
    # relies on bridge-nf-call-*tables being on (the kernel/docker default, left
    # untouched below) so that same-subnet bridged guest<->guest traffic is seen
    # by the FORWARD chain.
    networking.firewall.extraCommands = ''
      # delete-then-insert so a reload can't accumulate duplicates
      iptables  -D FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP 2>/dev/null || true
      iptables  -I FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP
      ip6tables -D FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP 2>/dev/null || true
      ip6tables -I FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP 2>/dev/null || true
    '';
    networking.firewall.extraStopCommands = ''
      iptables  -D FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP 2>/dev/null || true
      ip6tables -D FORWARD -i ${cfg.bridge} -o ${cfg.bridge} -j DROP 2>/dev/null || true
    '';
    # Deliberately NOT disabling the bridge-nf-call-* sysctls: they are what
    # routes bridged guest<->guest traffic through the FORWARD rule above, and
    # forcing them to 0 host-wide would change behavior for other bridge users
    # on the box (e.g. docker relies on bridge-nf-call-iptables=1).

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

    # ── State ─────────────────────────────────────────────────────────────────
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
      "d ${stateDir}/specs 0755 root root -"
      "d ${stateDir}/exposed 0755 root root -"
      "f ${stateDir}/dnsmasq-hosts 0644 root root -"
    ];

    # ── The daemon ────────────────────────────────────────────────────────────
    systemd.services.garnix-provisionerd = {
      description = "garnix local microVM provisioner";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "dnsmasq.service" ];
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
        PROVISIONER_UPLINK = cfg.uplinkInterface;
        PROVISIONER_SSH_PORT_BASE = toString cfg.sshExposePortBase;
        PROVISIONER_TCP_PORT_BASE = toString cfg.tcpExposePortBase;
      };
      serviceConfig = {
        # Derive the guest-facing public key from the hosting private key so
        # no separate pubkey secret is needed. Retried via Restart if the
        # secret isn't installed yet (e.g. agenix ordering on first boot).
        ExecStartPre = pkgs.writeShellScript "garnix-provisioner-pubkey" ''
          set -euo pipefail
          ${pkgs.openssh}/bin/ssh-keygen -y -f ${cfg.sshPrivateKeyPath} > ${pubkeyPath}
          chmod 0644 ${pubkeyPath}
        '';
        ExecStart = "${pkgs.python3}/bin/python3 ${./provisionerd.py}";
        RuntimeDirectory = "garnix-provisioner";
        Restart = "always";
        RestartSec = 5;
      };
      unitConfig.StartLimitIntervalSec = 0;
    };
  };
}
