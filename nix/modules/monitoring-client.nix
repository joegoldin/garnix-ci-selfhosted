{ config
, options
, lib
, pkgs
, ...
}:

let
  cfg = config.garnix.monitoring-client;
in

{
  options.garnix.monitoring-client = {
    enable = lib.mkEnableOption "garnix client monitoring";

    nodeId = lib.mkOption {
      type =
        let
          values = lib.attrNames config.garnix.monitoring.monitoredHosts;
          definitionPositions = lib.concatMapStringsSep "\n" (def: "  ${def.file}")
            options.garnix.monitoring.monitoredHosts.definitionsWithLocations;
        in
        lib.types.enum values // {
          description =
            lib.concatStringsSep "\n" [
              "one of the values of the option `garnix.monitoring.monitoredHosts`, defined at:"
              definitionPositions
              "Currently allowed values are:"
              ("  " + (lib.concatStringsSep ", " values))
              "Please make sure the nodeId for this machine has been added to the monitoredHosts."
            ];
        };
      description = "this server's prometheus endpoint";
    };

    nginx = {
      enable = lib.mkOption {
        type = lib.types.bool;
        description = "Whether to also setup nginx to forward to the node exporter";
        default = true;
      };

      basicAuthFile = lib.mkOption {
        type = lib.types.str;
        default = "/run/nginx/htpasswd-monitoring";
        description = "The file to store the basic auth credentials";
      };
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = if config.garnix.devMode.enable then "test" else config.garnix.monitoring.monitoredHosts.${cfg.nodeId}.fqdn;
      description = "The FQDN for this host's prometheus instance";
    };

    basicAuth = {
      username = lib.mkOption {
        type = lib.types.str;
        default = "prometheus";
      };
      passwordFile = lib.mkOption {
        type = lib.types.str;
        default = config.sops.secrets.prometheus-node-exporter-1.path;
      };
    };
  };

  config = lib.mkIf cfg.enable (
    # This has to be done like this to avoid nix complaining about either
    # missing module options that only exist on linux, or infinite recursion.
    if (builtins.hasAttr "launchd" options) then
      {
        services.prometheus.exporters.node.enable = true;
      }
    else
      lib.mkMerge [
        {
          sops.secrets.prometheus-node-exporter-1 = { };

          services.prometheus.exporters = {
            node = {
              enable = true;
              enabledCollectors = [ "systemd" "processes" ];
            };
            nginx.enable = config.garnix.monitoring.monitoredHosts.${cfg.nodeId}.scrapeNginx;
            nginxlog = {
              enable = config.garnix.monitoring.monitoredHosts.${cfg.nodeId}.scrapeNginxLog;
              group = "nginx";
              settings.namespaces = [
                {
                  name = "nginx";
                  source.files = [ "/var/log/nginx/json_access.log" ];
                  parser = "json";
                }
              ];
            };
          };
        }
        (lib.mkIf cfg.nginx.enable {
          security.acme = {
            acceptTerms = true;
            certs."${cfg.fqdn}" = {
              email = "jkarni@riseup.net";
            };
          };

          networking.firewall.allowedTCPPorts = [ 80 443 ];

          services.nginx = {
            enable = true;
            recommendedProxySettings = true;
            recommendedOptimisation = true;
            # This is needed for long domain names
            serverNamesHashBucketSize = 128;
            proxyTimeout = "600s";
            virtualHosts."${cfg.fqdn}" = config.garnix.devMode.withDevCerts {
              forceSSL = true;
              enableACME = true;
              locations = {
                "/" = {
                  inherit (cfg.nginx) basicAuthFile;
                  proxyPass = "http://[::1]:${toString config.services.prometheus.exporters.node.port}";
                };
                "/nginx" = lib.mkIf config.garnix.monitoring.monitoredHosts.${cfg.nodeId}.scrapeNginx {
                  inherit (cfg.nginx) basicAuthFile;
                  proxyPass = "http://[::1]:${toString config.services.prometheus.exporters.nginx.port}/metrics";
                };
                "/nginxlog" = lib.mkIf config.garnix.monitoring.monitoredHosts.${cfg.nodeId}.scrapeNginxLog {
                  inherit (cfg.nginx) basicAuthFile;
                  proxyPass = "http://[::1]:${toString config.services.prometheus.exporters.nginxlog.port}/metrics";
                };
                "/server-metrics" = lib.mkIf config.garnix.monitoring.monitoredHosts.${cfg.nodeId}.scrapeGarnixServer {
                  inherit (cfg.nginx) basicAuthFile;
                  proxyPass = "http://127.0.0.1:${toString config.services.garnixServer.metricsPort}/";
                };
              };
            };
          };

          # Create the htpasswd file for basic auth from the password that's stored in SOPS.
          # The nginx service runs with PrivateTmp set to true, so this file will only
          # be accessible to nginx.
          systemd.services = {
            nginx = {
              serviceConfig.LoadCredential = [
                "basicAuthPassword:${cfg.basicAuth.passwordFile}"
              ];

              preStart = ''
                ${pkgs.apacheHttpd}/bin/htpasswd -icm ${cfg.nginx.basicAuthFile} ${cfg.basicAuth.username} < "$CREDENTIALS_DIRECTORY/basicAuthPassword"
              '';
            };
          };
        })
      ]
  );
}
