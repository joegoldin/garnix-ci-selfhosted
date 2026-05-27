{ config
, lib
, pkgs
, flakePackages
, ...
}:
let
  cfg = config.garnix.ns1;
in
{
  options.garnix.ns1 = {
    enable = lib.mkEnableOption "dns server";
  };

  config = lib.mkIf cfg.enable {
    networking.firewall = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 ];
    };

    systemd.services.dns-server = {
      description = "dns server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        User = "dns";
        DynamicUser = true;
        AmbientCapabilities = "cap_net_bind_service";
        CapabilityBoundingSet = "cap_net_bind_service";
        Environment = [
          "API_ORIGIN=https://garnix.io"
        ];
      };
      script = lib.getExe (pkgs.writeShellApplication {
        name = "dns-start-script";
        runtimeInputs = [
          pkgs.jq
          pkgs.iproute2
          flakePackages.dns
        ];
        text = ''
          addrs=$(ip --json address | \
            jq --raw-output '
              map(
                select(.ifname != "lo") |
                .addr_info[] |
                select(.family != "inet6" and .scope == "global" and ((.deprecated or .temporary) | not))
                .local + ":53"
              ) | join(",")')
          export LISTEN_ADDRS="''${addrs},[::1]:53"
          echo "Listening on addresses ''${LISTEN_ADDRS}"
          dns
        '';
      });
    };
  };
}
