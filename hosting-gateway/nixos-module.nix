{ config
, lib
, pkgs
, flakePackages
, ...
}:
let
  cfg = config.garnix.hosting-gateway;
  basicAuthFile = "/run/traefik/htpasswd-monitoring";

  traefikPort = 8080;
  onDemandResolverPort = 8081;
in
{
  options.garnix.hosting-gateway = {
    enable = lib.mkEnableOption "hosting gateway";
    serverMappingEndpoint = lib.mkOption {
      type = lib.types.str;
      description = "URL to query for latest server mappings";
    };
    pollInterval = lib.mkOption {
      type = lib.types.int;
      description = "How often (in seconds) to poll server mapping endpoint";
      default = 5;
    };
    extraCaddyAcmeConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      description = "Extra options appended to apps.tls.automation.policies[0].issuers[0] in services.caddy.settings";
      default = { };
    };
    garnixOrigin = lib.mkOption {
      type = lib.types.str;
      description = "The origin of the garnix server to request valid domain names";
      default = "https://garnix.io";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ 80 443 ];

    # We forward to the node exporter ourselves, via traefik
    garnix.monitoring-client.nginx.enable = false;

    systemd.services.caddyOnDemandResolver = {
      # This is used by the Caddy "on_demand.ask" configuration documented here:
      # https://caddyserver.com/docs/json/apps/tls/automation/on_demand/permission/http/
      description = "A http service that caddy calls to determine if an on-demand request for a TLS certificate is valid";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = lib.getExe flakePackages."hosting-gateway/onDemandResolver";
      };
      environment.PORT = toString onDemandResolverPort;
      environment.GARNIX_ORIGIN = cfg.garnixOrigin;
    };
    services.caddy = {
      enable = true;
      settings = {
        apps = {
          tls.certificates.automate = [ config.garnix.monitoring-client.fqdn ];
          tls.automation = {
            policies = [
              {
                subjects = [ config.garnix.monitoring-client.fqdn ];
                issuers = [
                  ({
                    module = "acme";
                    email = config.security.acme.defaults.email;
                  } // config.garnix.hosting-gateway.extraCaddyAcmeConfig)
                ];
                storage = {
                  module = "file_system";
                  root = "/var/lib/caddy";
                };
                on_demand = false;
              }
              {
                issuers = [
                  ({
                    module = "acme";
                    email = config.security.acme.defaults.email;
                  } // config.garnix.hosting-gateway.extraCaddyAcmeConfig)
                ];
                storage = {
                  module = "file_system";
                  root = "/var/lib/caddy";
                };
                on_demand = true;
              }
            ];
            on_demand.permission = {
              module = "http";
              endpoint = "http://localhost:${toString onDemandResolverPort}/";
            };
          };
          http.servers."tlstermination" = {
            listen = [ ":443" ];
            routes = [{
              handle = [{
                handler = "reverse_proxy";
                upstreams = [{ dial = "localhost:${toString traefikPort}"; }];
              }];
            }];
          };
        };
      };
    };
    services.traefik = {
      enable = true;
      staticConfigOptions = {
        log.level = "DEBUG";
        entryPoints.http = {
          address = ":${toString traefikPort}";
          forwardedHeaders.insecure = true;
        };
        providers.http = {
          endpoint = cfg.serverMappingEndpoint;
          pollInterval = "${toString cfg.pollInterval}s";
        };
        hostResolver = {
          cnameFlattening = true;
          resolvDepth = 2;
        };
        experimental.localPlugins.heartbeatmiddleware = {
          moduleName = "github.com/garnix-io/garnix/heartbeatmiddleware";
        };
      };
      dynamicConfigOptions = {
        http = {
          middlewares = {
            node-exporter-basic-auth = {
              basicAuth = {
                usersFile = basicAuthFile;
              };
            };
          };
          routers = {
            node-exporter-router = {
              rule = "Host(`${config.garnix.monitoring-client.fqdn}`)";
              service = "node-exporter";
              middlewares = [ "node-exporter-basic-auth" ];
            };
          };
          services = {
            node-exporter = {
              loadBalancer.servers =
                [{ url = "http://localhost:${toString config.services.prometheus.exporters.node.port}"; }];
            };
          };
        };
      };
    };

    systemd.services.traefik =
      let
        auth = config.garnix.monitoring-client.basicAuth;
      in
      {
        serviceConfig = {
          RuntimeDirectoryMode = 0750;
          ExecStartPre = [
            (pkgs.lib.getExe (pkgs.writeShellApplication {
              name = "init-traefik-plugins";
              runtimeInputs = [ pkgs.coreutils ];
              text = ''
                PLUGINS_DIR=/var/lib/traefik/plugins-local/src/github.com/garnix-io/garnix
                mkdir -p "$PLUGINS_DIR"
                cp -r ${./heartbeatmiddleware} "$PLUGINS_DIR/heartbeatmiddleware"
              '';
            }))
          ];
          LoadCredential = [
            "basicAuthPassword:${auth.passwordFile}"
          ];
        };

        preStart = ''
          ${pkgs.apacheHttpd}/bin/htpasswd -icm ${basicAuthFile} ${auth.username} < "$CREDENTIALS_DIRECTORY/basicAuthPassword"
        '';
      };
  };
}
