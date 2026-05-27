{ config
, lib
, ...
}:

let
  cfg = config.garnix.monitoring-server;
  prometheus-basic-auth = "/run/prometheus/prometheus-basic-auth";
in
{
  options.garnix.monitoring-server = {
    enable = lib.mkEnableOption "garnix monitoring server";
  };

  config = lib.mkIf cfg.enable {
    sops = {
      secrets.prometheus-node-exporter-1 = { };
    };

    garnix.watchdog.enable = true;

    services.grafana = {
      enable = true;
      settings = {
        server.http_port = 2432;
        date_formats.default_timezone = "utc";
        server = {
          domain = "monitoring.garnix.io";
          root_url = "https://monitoring.garnix.io";
        };
      };
      provision = {
        enable = true;

        dashboards.settings.providers = [
          {
            name = "garnixServer";
            options.path = ../data/grafana-node-exporter-full.json;
          }
        ];

        datasources.settings.datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            url = "http://localhost:${toString config.services.prometheus.port}";
            jsonData = {
              timeInterval = config.services.prometheus.globalConfig.scrape_interval;
            };
          }
        ];
      };
    };

    services.prometheus = {
      enable = true;
      port = 2433;
      globalConfig = {
        scrape_interval = "30s";
        scrape_timeout = "10s";
      };
      retentionTime = "90d";
      scrapeConfigs =
        let
          formatTarget = monitoredHost:
            if monitoredHost.port == null
            then monitoredHost.fqdn
            else "${monitoredHost.fqdn}:${toString monitoredHost.port}";
        in
        [
          {
            job_name = "node";
            scheme = "https";
            basic_auth = {
              username = config.garnix.monitoring-client.basicAuth.username;
              password_file = prometheus-basic-auth;
            };
            static_configs = [{
              targets =
                lib.mapAttrsToList (_: e: formatTarget e)
                  (lib.filterAttrs (_:e: e.proxied)
                    config.garnix.monitoring.monitoredHosts);
            }];
          }
          {
            job_name = "node_unproxied";
            scheme = "http";
            static_configs = [{
              targets =
                lib.mapAttrsToList (_: e: formatTarget e)
                  (lib.filterAttrs (_:e: ! e.proxied)
                  config.garnix.monitoring.monitoredHosts);
            }];
          }
          {
            job_name = "nginx";
            scheme = "https";
            basic_auth = {
              username = config.garnix.monitoring-client.basicAuth.username;
              password_file = prometheus-basic-auth;
            };
            metrics_path = "/nginx";
            static_configs = [{
              targets = lib.mapAttrsToList (_: e: e.fqdn) (lib.filterAttrs (_:e: e.scrapeNginx) config.garnix.monitoring.monitoredHosts);
            }];
          }
          {
            job_name = "nginxlog";
            scheme = "https";
            basic_auth = {
              username = config.garnix.monitoring-client.basicAuth.username;
              password_file = prometheus-basic-auth;
            };
            metrics_path = "/nginxlog";
            static_configs = [{
              targets = lib.mapAttrsToList (_: e: e.fqdn) (lib.filterAttrs (_:e: e.scrapeNginxLog) config.garnix.monitoring.monitoredHosts);
            }];
          }
          {
            job_name = "sql";
            scheme = "https";
            basic_auth = {
              username = config.garnix.monitoring-client.basicAuth.username;
              password_file = prometheus-basic-auth;
            };
            static_configs = [{
              targets = [ "prometheus-sql-exporter.garnix.io" ];
            }];
          }
          {
            job_name = "server-metrics";
            scheme = "https";
            basic_auth = {
              username = config.garnix.monitoring-client.basicAuth.username;
              password_file = prometheus-basic-auth;
            };
            metrics_path = "/server-metrics";
            static_configs = [{
              targets = lib.mapAttrsToList (_: e: e.fqdn) (lib.filterAttrs (_:e: e.scrapeGarnixServer) config.garnix.monitoring.monitoredHosts);
            }];
          }
        ];
    };

    systemd.services.prometheus = {
      serviceConfig = {
        PrivateTmp = true;
        LoadCredential = [
          "basicAuthPassword:${config.garnix.monitoring-client.basicAuth.passwordFile}"
        ];
      };
      unitConfig.RequiresMountsFor = [ config.systemd.services.prometheus.serviceConfig.WorkingDirectory ];
      preStart = ''
        cp "$CREDENTIALS_DIRECTORY/basicAuthPassword" ${prometheus-basic-auth}
      '';
    };

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedOptimisation = true;
      proxyTimeout = "600s";
      virtualHosts = {
        "monitoring.garnix.io" = config.garnix.devMode.withDevCerts {
          addSSL = true;
          enableACME = true;
          locations."/".proxyPass = "http://${config.services.grafana.settings.server.http_addr}:" + toString config.services.grafana.settings.server.http_port;
          locations."/api/live" = {
            proxyPass = "http://${config.services.grafana.settings.server.http_addr}:" + toString config.services.grafana.settings.server.http_port;
            proxyWebsockets = true;
          };
        };
      };
    };
    security.acme.certs."monitoring.garnix.io" = { };

  };
}
