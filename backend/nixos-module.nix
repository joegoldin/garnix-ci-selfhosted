{
  config,
  lib,
  pkgs,
  flakePackages,
  flakeInputs,
  ...
}:
let
  buildLogsFluentBitPort = 8888;
  serverTierNames = [
    "i1x1"
    "i1x2"
    "i2x2"
    "i2x3"
    "i2x4"
    "i4x2"
    "i4x4"
    "i4x8"
    "i8x8"
    "i8x16"
    "i16x16"
    "i16x32"
  ];
  serverPoolEnv = lib.concatStringsSep "," (
    lib.mapAttrsToList (tier: count: "${tier}:${toString count}") (
      lib.filterAttrs (_: count: count > 0) config.services.garnixServer.serverPool
    )
  );

  logsDir = pkgs.writeShellScriptBin "logsDir" ''
    if [ -d /var/lib/garnix/logs ]; then
      echo "Logs dir exists. Not creating"
    else
      mkdir /var/lib/garnix/logs
    fi
  '';

  migrateScript =
    with pkgs;
    writeShellScriptBin "migrate" ''
      set -euo pipefail

      export SQITCH_PASSWORD=$(cat /run/secrets/database-password)
      ${lib.getBin flakePackages."backend_migrate"}/bin/sqitch deploy \
          "db:pg://${config.garnix.database.dbUser}:$(cat /run/secrets/database-password)@${config.garnix.database.fqdn}:${toString config.garnix.database.dbPort}/${config.garnix.database.dbName}?sslmode=${config.garnix.database.ssl.mode}&sslrootcert=${config.garnix.database.ssl.rootCert}"
    '';
  dbCheckIsReady =
    with pkgs;
    writeShellScriptBin "dbCheckIsReady" ''
      #!/usr/bin/env bash
      set -uo pipefail

      max_retries=10
      retry_interval=2
      retries=0
      start_time=$(date +%s)

      export PGPASSWORD=$(cat /run/secrets/database-password)
      echo $PGHOST

      while true; do
        end_time=$(date +%s)
        ${flakePackages."backend_postgres"}/bin/psql -c "SELECT 1;" >/dev/null
        #shellcheck disable=SC2181
        if [ $? -eq 0 ]; then
          elapsed_time=$((end_time - start_time))
          echo "Postgresql is ready to handle queries after $elapsed_time seconds."
          break
        fi

        retries=$((retries + 1))

        if [ $retries -ge $max_retries ]; then
          echo "Maximum retries reached. Readiness condition not met."
          exit 1
        fi

        echo "Readiness condition not met. Retrying in $retry_interval seconds..."
        sleep $retry_interval
      done
    '';
in
{
  options = {
    garnix.manageSecretsWithSops = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Declare sops.secrets (upstream behavior). Set false when secrets are provided externally at /run/secrets/<name> (e.g. agenix).";
    };

    services = {
      garnixServer = {
        enable = lib.mkEnableOption "garnix server";
        url = lib.mkOption {
          type = lib.types.str;
          default = "https://app.garnix.io";
        };
        cacheUrl = lib.mkOption {
          type = lib.types.str;
          default = "https://cache.garnix.io";
        };
        cachePublicKey = lib.mkOption {
          type = lib.types.str;
          default = "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g=";
        };
        selfHostMode = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Run as a single-tenant self-hosted instance: disable all billing limits and gate login behind an authenticating reverse proxy that injects the X-Auth-Request-Groups header.";
        };
        adminGroup = lib.mkOption {
          type = lib.types.str;
          default = "garnix-admins";
          description = "In self-host mode, membership of this proxy-injected group sets a user's subscription_type to admin on each login.";
        };
        modulesOrg = lib.mkOption {
          type = lib.types.str;
          default = "garnix-io";
          description = "The GitHub org whose repositories are allowed to publish Garnix modules. Set this to your own org to publish modules from a self-hosted instance.";
        };
        buildNetRcFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Optional netrc file for authenticating to extra substituters (e.g. a private attic cache) during sandboxed evals/builds. Bound read-only into the build sandbox; must be readable by the garnix server user.";
        };
        giteaUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "https://gitea.example.com";
          description = ''
            Base URL of an optional self-hosted Gitea instance to integrate as a
            second forge alongside GitHub (no trailing slash). When null, garnix
            is GitHub-only. When set, the backend also serves Gitea webhooks at
            /api/events/gitea and reports build status via Gitea commit statuses.
            The API token and webhook secret are read from /run/secrets/gitea-token
            and /run/secrets/gitea-webhook-secret (provision them like the other
            garnix secrets); the server user must be able to read them.
          '';
        };
        hostingDomain = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "apps.garnix.example.com";
          description = ''
            Base domain under which deployed servers are exposed. Deployed
            servers get <package>.<branch>.<repo>.<owner>.<hostingDomain>.
            When null, the upstream default (garnix.me) is used.
          '';
        };
        statsReportUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "https://garnix.example.com/api/hosts/stats";
          description = ''
            Full control-plane URL that deployed guests POST CPU and memory
            samples to. Sets GARNIX_STATS_REPORT_URL. When null, the backend
            defaults to <services.garnixServer.url>/api/hosts/stats. Keep this
            separate from hostingDomain, which routes untrusted workloads.
          '';
        };
        extraHostingDomains = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "example.dev" ];
          description = "Extra wildcard base domains the operator owns; servers can be hosted at <name>.<domain>. Each needs a manual wildcard *.<domain> -> host DNS record. Sets GARNIX_EXTRA_HOSTING_DOMAINS.";
        };
        hostingPublicIp = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "203.0.113.10";
          description = "Public IP of the garnix host, shown in A-record instructions for bare custom domains. Sets GARNIX_HOSTING_PUBLIC_IP.";
        };
        metricsScrapeUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "http://127.0.0.1:8323/";
          description = "Where the self-host monitoring page scrapes garnix's own Prometheus metrics. The endpoint serves at the root path (not /metrics). Defaults to http://127.0.0.1:<metricsPort>/.";
        };
        nodeExporterUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "http://127.0.0.1:9100/metrics";
          description = "Legacy single-host node-exporter target. Used when monitoringBuilders is empty.";
        };
        monitoringBuilders = lib.mkOption {
          default = [ ];
          description = "Builder node-exporter targets shown on the self-host monitoring page.";
          type = lib.types.listOf (
            lib.types.submodule {
              options = {
                name = lib.mkOption {
                  type = lib.types.str;
                  description = "Builder display name.";
                };
                url = lib.mkOption {
                  type = lib.types.str;
                  example = "http://builder.example.com:9100/metrics";
                  description = "Node-exporter metrics URL reachable from garnixServer.";
                };
                systems = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  example = [ "aarch64-linux" ];
                  description = "Nix systems this builder supports.";
                };
                maxJobs = lib.mkOption {
                  type = lib.types.ints.unsigned;
                  default = 0;
                  description = "Maximum concurrent build jobs; zero means unspecified.";
                };
              };
            }
          );
        };
        sshHost = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "erdtree";
          description = ''
            External SSH host the Servers page uses to build the ssh command for
            a deployed server's DNAT'd SSH port (e.g. erdtree's tailscale name or
            public hostname). Surfaced via /api/config as ssh_host.
          '';
        };
        proxySharedSecretFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/run/secrets/garnix_proxy_shared_secret";
          description = ''
            File containing the shared secret the trusted reverse proxy injects
            as the X-Garnix-Proxy-Auth request header. In selfHostMode the
            backend only honors X-Auth-Request-* identity headers when the
            request carries this header with the file's (trailing-whitespace-
            trimmed) contents. Sets GARNIX_PROXY_SHARED_SECRET_FILE when
            configured. When null, this module sets no file-backed secret; a
            manually supplied development-only GARNIX_PROXY_SHARED_SECRET can
            be used instead, otherwise proxy-header authentication fails closed.
            This option deliberately never places the secret value in the unit
            environment (unit properties are world-readable via systemctl show).
          '';
        };
        terminalCaKeyPath = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/run/secrets/garnix_terminal_ca";
          description = ''
            Path to a dedicated SSH CA private key used ONLY to sign the
            short-lived web-terminal session certificates (Garnix.API.Terminal).
            Guests trust its public key as TrustedUserCAKeys, so the
            hosting/deploy key stops being a certificate mint and this CA key
            grants no direct login. Sets GARNIX_TERMINAL_CA_KEY; when null the
            backend falls back to /run/secrets/garnix_terminal_ca. If that file
            is absent the web terminal fails closed (no hosting-key fallback).
          '';
        };
        terminalSourceAddress = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "10.111.0.1/32";
          description = ''
            CIDR the backend bakes into web-terminal certs as
            `-O source-address` (GARNIX_TERMINAL_SOURCE_ADDRESS): the host's own
            address on the guest bridge, so a minted cert only authenticates
            from the backend. null omits the restriction.
          '';
        };
        actionHost = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "127.0.0.1";
          description = ''
            SSH host garnix runs `action` app executions on: it `nix copy`s the
            action closure to `action-runner@<actionHost>` and executes it there.
            Upstream defaults to garnix's own runner fleet; for self-host point
            this at a host running the action-runner module (typically
            "127.0.0.1" with `garnix.actionRunner.enable = true`). Sets
            GARNIX_ACTION_HOST. When null, actions won't run on a self-host box.
          '';
        };
        s3Artifacts = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.submodule {
              options = {
                publicBucket = lib.mkOption { type = lib.types.str; };
                privateBucket = lib.mkOption { type = lib.types.str; };
                publicBaseUrl = lib.mkOption { type = lib.types.str; };
              };
            }
          );
          default = null;
          description = ''
            Build-artifact buckets (garnix.yaml `artifacts:`). Key pairs are read from
            /run/secrets/s3-artifacts-{public,private}-{access-key-id,secret-access-key}.
            Feature is off when null.
          '';
        };
        provisionerSocket = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/run/garnix-provisioner/provisioner.sock";
          description = ''
            Unix socket of a local garnix-provisionerd daemon. Server
            deployments provision local microVMs through it
            (see provisioner/nixos-module.nix).
          '';
        };
        defaultAuthentik = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.submodule {
              options = {
                issuerUrl = lib.mkOption {
                  type = lib.types.str;
                  example = "https://authentik.example.com/application/o/garnix/";
                  description = "OIDC issuer URL of garnix's own Authentik application.";
                };
                clientId = lib.mkOption {
                  type = lib.types.str;
                  description = "OIDC client id of garnix's own Authentik application.";
                };
                clientSecretFile = lib.mkOption {
                  type = lib.types.str;
                  description = "File containing the OIDC client secret (read at deploy time; must be readable by the garnix server user).";
                };
              };
            }
          );
          default = null;
          description = ''
            garnix's own OIDC client (the Authentik application fronting garnix
            itself). When set, a deployment whose garnix.yaml servers entry has
            `authentik: default` gets these credentials dropped onto the guest
            at /var/garnix/keys/default-authentik.env, so the guest's
            garnix-authentik module (mode = "default") gates the service behind
            the exact same login as garnix. The Authentik provider must allow
            the deployed servers' redirect URIs (e.g. a regex redirect URI
            covering https://*.<hostingDomain>/oauth2/callback).
          '';
        };
        githubAppName = lib.mkOption {
          type = lib.types.str;
          default = "garnix-ci";
        };
        port = lib.mkOption {
          type = lib.types.int;
          default = 8321;
        };
        monitoringPort = lib.mkOption {
          type = lib.types.int;
          default = 8322;
        };
        metricsPort = lib.mkOption {
          type = lib.types.int;
          default = 8323;
        };
        opensearchUrl = lib.mkOption {
          type = lib.types.str;
          example = "https://<opensearch-ip>/_msearch";
        };
        testFeatures = lib.mkOption {
          type = lib.types.listOf (
            lib.types.enum [
              "DevApi"
              "OpenSearchMocks"
              "CacheUploadMocks"
            ]
          );
          default = [ ];
        };
        provisionServerPool = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
        serverPool = lib.mkOption {
          type = lib.types.submodule {
            options = lib.genAttrs serverTierNames (
              _:
              lib.mkOption {
                type = lib.types.ints.unsigned;
                default = 0;
              }
            );
          };
          default = {
            i1x1 = 1;
          };
          description = ''
            Number of pre-warmed local hosting guests for each machine tier.
            A deployment can only claim a tier present in this pool. This is
            rendered as GARNIX_SERVER_POOL for the backend.
          '';
        };
        maxLocalJobs = lib.mkOption {
          type = lib.types.int;
          default = 0;
          description = "max-jobs for local builds in production mode (0 = never build locally, farm everything to buildMachines)";
        };
        maxConcurrentBuilds = lib.mkOption {
          type = lib.types.int;
          default = 16;
          description = ''
            Concurrent-build cap. Every package still fans out and registers as a
            pending check immediately; this bounds how many actually eval+build at
            once (the rest queue, staying pending, and flip to running when a slot
            frees — round-robin fair by repo owner). Bounds guest fan-out and the
            log-shipping load on fluent-bit during big multi-commit pushes. Sets
            GARNIX_MAX_CONCURRENT_BUILDS.
          '';
        };
        maxRemoteFodJobs = lib.mkOption {
          type = lib.types.ints.positive;
          default = 1;
          description = ''
            Maximum number of fixed-output derivation checks allowed to use a
            remote Nix store concurrently. FOD checks connect to the store
            directly and bypass the Nix daemon's buildMachines.maxJobs
            scheduler, so small external builders need this separate cap. Sets
            GARNIX_FOD_REMOTE_MAX_JOBS.
          '';
        };
        enableNginx = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to configure the built-in nginx vhosts for the server/frontend. Disable when an external reverse proxy handles this instead.";
        };
        journaldMaxUse = lib.mkOption {
          type = lib.types.str;
          default = "100G";
          description = "SystemMaxUse setting for journald.";
        };
        buildMachines = lib.mkOption {
          type = lib.types.listOf (
            lib.types.submodule {
              options = {
                hostName = lib.mkOption { type = lib.types.str; };
                hostAddress = lib.mkOption { type = lib.types.str; };
                sshUser = lib.mkOption {
                  type = lib.types.str;
                  default = "nix-ssh";
                };
                sshKey = lib.mkOption {
                  type = lib.types.str;
                  default = "/run/secrets/garnix_server_remote_builder_ssh";
                };
                protocol = lib.mkOption {
                  type = lib.types.str;
                  default = "ssh-ng";
                };
                systems = lib.mkOption { type = lib.types.listOf lib.types.str; };
                maxJobs = lib.mkOption {
                  type = lib.types.int;
                  default = 4;
                };
                speedFactor = lib.mkOption {
                  type = lib.types.int;
                  default = 1;
                };
                supportedFeatures = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ "big-parallel" ];
                };
                mandatoryFeatures = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                };
              };
            }
          );
          default = [ ];
          description = "Remote builders. Replaces upstream's hardcoded fleet.";
        };
        s3Cache = {
          publicBucket = lib.mkOption {
            type = lib.types.str;
          };
          publicBaseUrl = lib.mkOption {
            type = lib.types.str;
          };
          privateBucket = lib.mkOption {
            type = lib.types.str;
          };
          host = lib.mkOption {
            type = lib.types.str;
          };
          region = lib.mkOption {
            type = lib.types.str;
            default = "auto";
          };
        };
      };

      frontend = {
        port = lib.mkOption {
          type = lib.types.int;
          default = 3000;
        };
      };
    };
  };

  config = lib.mkIf config.services.garnixServer.enable {
    assertions = [
      {
        assertion = !config.garnix.devMode.enable -> (config.services.garnixServer.testFeatures == [ ]);
        message = ''
          Test features cannot be enabled in production.
          If you want to enable test features, set garnix.devMode.enable to true.
        '';
      }
    ];

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];

    environment.systemPackages = [ pkgs.postgresql_18 ];

    programs.ssh = {
      startAgent = true;
      extraConfig = ''
        AddKeysToAgent yes
      ''
      + lib.concatMapStrings (m: ''
        Host ${m.hostName}
           Hostname ${m.hostAddress}
           User ${m.sshUser}
           IdentityFile ${m.sshKey}
      '') config.services.garnixServer.buildMachines;
    };

    nix = {
      settings = {
        cores = 4;
      };
      extraOptions = ''
        max-jobs = ${
          if config.garnix.devMode.enable then "auto" else toString config.services.garnixServer.maxLocalJobs
        }
        keep-build-log = true
      '';
      buildMachines = map (m: {
        inherit (m)
          hostName
          sshUser
          sshKey
          protocol
          systems
          maxJobs
          speedFactor
          supportedFeatures
          mandatoryFeatures
          ;
      }) config.services.garnixServer.buildMachines;
      distributedBuilds =
        !config.garnix.devMode.enable && config.services.garnixServer.buildMachines != [ ];
      daemonIOSchedPriority = 4;
    };

    virtualisation.vmVariant = { lib, ... }: {
      services.garnixServer = {
        url = "https://testing.garnix.io";
        githubAppName = "test-app-jkarni";
      };
    };

    garnix = {
      custom-gc = {
        enable = true;
        enableTimer = true;
        useNixHeuristicGc = false;
        upperLimitPercent = null;
      };
      fluent-bit.enableNginxLogParsing = true;
      fluent-bit.configuration.pipelines.build-logs =
        let
          tag = "build-logs";
        in
        {
          input = {
            Name = "http";
            Tag = tag;
            listen = "::1";
            port = buildLogsFluentBitPort;
            # The backend ships each build-log line as its own POST. During a big
            # multi-commit push dozens of builds ship concurrently; fluent-bit's
            # default accept backlog (128) saturates and the backend's POSTs time
            # out (silently dropped — shipping is best-effort). Give the listener
            # a deeper accept queue and its own thread so it keeps draining
            # connections while the OpenSearch output flushes.
            "net.backlog" = 1024;
            Threaded = "On";
          };
          output = {
            Name = "opensearch";
            Match = tag;
            Host = config.garnix.fluent-bit.opensearch.fqdn;
            Port = config.garnix.fluent-bit.opensearch.port;
            Tls = if config.garnix.fluent-bit.opensearch.tls then "On" else "Off";
            "Tls.verify" = if config.garnix.devMode.enable then "Off" else "On";
            HTTP_User = config.garnix.fluent-bit.opensearch.basicAuth.username;
            HTTP_Passwd = "\${OPENSEARCH_PASSWORD}";
            Logstash_Format = "On";
            Logstash_Prefix = "garnix-build-logs";
            Logstash_DateFormat = "%Y.%m.%d";
            Time_Key = "@timestamp";
            Time_Key_Nanos = "On";
            Replace_Dots = "On";
            Suppress_Type_Name = "On";
            Index = "fluent-bit";
          };
        };
    };

    systemd.services.garnixServer = {
      description = "The garnix server";
      # Coreutils is needed so we have the right version of 'tail', allowing
      # use of the --pid option
      path = with pkgs; [
        git
        config.nix.package
        coreutils
        util-linux
        bzip2
        openssh
        age
        flakeInputs.comment.packages.${stdenv.hostPlatform.system}.default
      ];
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "notify";
        User = config.garnix.database.dbUser;
        RestartSec = 1;
        Restart = "always";
        StartLimitBurst = 3;
        TimeoutStopSec = 5;
        KillSignal = "SIGINT";
        # If you change this, also change the build-logs-dir option
        StateDirectory = "garnix";
        PrivateTmp = false;
        LimitNOFILE = 1048576;
        Environment = [
          "PGPORT=${toString config.garnix.database.dbPort}"
          "PGUSER=${config.garnix.database.dbUser}"
          "PGDATABASE=${config.garnix.database.dbName}"
          "PGHOST=${config.garnix.database.fqdn}"
          "PGSSLMODE=${config.garnix.database.ssl.mode}"
          "PGSSLROOTCERT=${config.garnix.database.ssl.rootCert}"
          "TPG_TLS=true"
          "TPG_TLS_MODE=full"
          "TPG_HOST=${toString config.garnix.database.fqdn}"
          "TPG_PORT=${toString config.garnix.database.dbPort}"
          "TPG_USER=${config.garnix.database.dbUser}"
          "TPG_DB=${config.garnix.database.dbName}"
          "GARNIX_URL=${config.services.garnixServer.url}"
          "GARNIX_CACHE_URL=${config.services.garnixServer.cacheUrl}"
          "GARNIX_CACHE_PUBLIC_KEY=${config.services.garnixServer.cachePublicKey}"
          "GITHUB_APP_NAME=${config.services.garnixServer.githubAppName}"
          "OPENSEARCH_URL=${config.services.garnixServer.opensearchUrl}"
          "S3_CACHE_REGION=${config.services.garnixServer.s3Cache.region}"
          "S3_CACHE_HOST=${config.services.garnixServer.s3Cache.host}"
          "S3_CACHE_PUBLIC_BUCKET=${config.services.garnixServer.s3Cache.publicBucket}"
          "S3_CACHE_PUBLIC_BASE_URL=${config.services.garnixServer.s3Cache.publicBaseUrl}"
          "S3_CACHE_PRIVATE_BUCKET=${config.services.garnixServer.s3Cache.privateBucket}"
          "GARNIX_MODULES_ORG=${config.services.garnixServer.modulesOrg}"
          "GARNIX_MAX_CONCURRENT_BUILDS=${toString config.services.garnixServer.maxConcurrentBuilds}"
          "GARNIX_FOD_REMOTE_MAX_JOBS=${toString config.services.garnixServer.maxRemoteFodJobs}"
        ]
        ++ lib.optionals config.services.garnixServer.selfHostMode [
          "GARNIX_SELF_HOST_MODE=1"
          "GARNIX_ADMIN_GROUP=${config.services.garnixServer.adminGroup}"
        ]
        ++ lib.optionals (config.services.garnixServer.buildNetRcFile != null) [
          "GARNIX_BUILD_NETRC_FILE=${config.services.garnixServer.buildNetRcFile}"
        ]
        ++ lib.optionals (config.services.garnixServer.giteaUrl != null) [
          # Token + webhook secret are read from /run/secrets/gitea-token and
          # /run/secrets/gitea-webhook-secret by the backend.
          "GITEA_URL=${config.services.garnixServer.giteaUrl}"
        ]
        ++ lib.optionals (config.services.garnixServer.hostingDomain != null) [
          "GARNIX_HOSTING_DOMAIN=${config.services.garnixServer.hostingDomain}"
        ]
        ++ lib.optionals (config.services.garnixServer.statsReportUrl != null) [
          "GARNIX_STATS_REPORT_URL=${config.services.garnixServer.statsReportUrl}"
        ]
        ++ lib.optionals (config.services.garnixServer.extraHostingDomains != [ ]) [
          "GARNIX_EXTRA_HOSTING_DOMAINS=${lib.concatStringsSep "," config.services.garnixServer.extraHostingDomains}"
        ]
        ++ lib.optionals (config.services.garnixServer.hostingPublicIp != null) [
          "GARNIX_HOSTING_PUBLIC_IP=${config.services.garnixServer.hostingPublicIp}"
        ]
        ++ lib.optionals (config.services.garnixServer.provisionerSocket != null) [
          "GARNIX_PROVISIONER_SOCKET=${config.services.garnixServer.provisionerSocket}"
        ]
        ++ lib.optionals config.services.garnixServer.provisionServerPool [
          "GARNIX_SERVER_POOL=${serverPoolEnv}"
        ]
        ++ lib.optionals (config.services.garnixServer.actionHost != null) [
          "GARNIX_ACTION_HOST=${config.services.garnixServer.actionHost}"
        ]
        ++ lib.optionals (config.services.garnixServer.s3Artifacts != null) [
          "S3_ARTIFACTS_PUBLIC_BUCKET=${config.services.garnixServer.s3Artifacts.publicBucket}"
          "S3_ARTIFACTS_PRIVATE_BUCKET=${config.services.garnixServer.s3Artifacts.privateBucket}"
          "S3_ARTIFACTS_PUBLIC_BASE_URL=${config.services.garnixServer.s3Artifacts.publicBaseUrl}"
        ]
        ++ lib.optionals (config.services.garnixServer.metricsScrapeUrl != null) [
          "GARNIX_METRICS_SCRAPE_URL=${config.services.garnixServer.metricsScrapeUrl}"
        ]
        ++ lib.optionals (config.services.garnixServer.nodeExporterUrl != null) [
          "GARNIX_NODE_EXPORTER_URL=${config.services.garnixServer.nodeExporterUrl}"
        ]
        ++ lib.optionals (config.services.garnixServer.monitoringBuilders != [ ]) [
          "GARNIX_MONITORING_BUILDERS=${builtins.toJSON config.services.garnixServer.monitoringBuilders}"
        ]
        ++ lib.optionals (config.services.garnixServer.sshHost != null) [
          "GARNIX_SSH_HOST=${config.services.garnixServer.sshHost}"
        ]
        ++ lib.optionals (config.services.garnixServer.proxySharedSecretFile != null) [
          "GARNIX_PROXY_SHARED_SECRET_FILE=${config.services.garnixServer.proxySharedSecretFile}"
        ]
        ++ lib.optionals (config.services.garnixServer.terminalCaKeyPath != null) [
          "GARNIX_TERMINAL_CA_KEY=${config.services.garnixServer.terminalCaKeyPath}"
        ]
        ++ lib.optionals (config.services.garnixServer.terminalSourceAddress != null) [
          "GARNIX_TERMINAL_SOURCE_ADDRESS=${config.services.garnixServer.terminalSourceAddress}"
        ]
        ++ lib.optionals (config.services.garnixServer.defaultAuthentik != null) [
          "GARNIX_DEFAULT_AUTHENTIK_ISSUER=${config.services.garnixServer.defaultAuthentik.issuerUrl}"
          "GARNIX_DEFAULT_AUTHENTIK_CLIENT_ID=${config.services.garnixServer.defaultAuthentik.clientId}"
          "GARNIX_DEFAULT_AUTHENTIK_CLIENT_SECRET_FILE=${config.services.garnixServer.defaultAuthentik.clientSecretFile}"
        ];
        SupplementaryGroups = [ config.users.groups.keys.name ];
        ExecStartPre = [
          "${dbCheckIsReady}/bin/dbCheckIsReady"
          "${migrateScript}/bin/migrate"
          "${logsDir}/bin/logsDir"
        ];
        ExecStart = ''
          ${lib.getBin flakePackages."backend_garnix"}/bin/server \
              ${
                lib.concatStringsSep " " (
                  builtins.map (testFeature: "--enable ${testFeature}") config.services.garnixServer.testFeatures
                )
              } \
              --port ${toString config.services.garnixServer.port} \
              --monitoring-port ${toString config.services.garnixServer.monitoringPort} \
              --metrics-port ${toString config.services.garnixServer.metricsPort} \
              --build-logs-reporting-port ${toString buildLogsFluentBitPort} \
              --build-logs-dir /var/lib/garnix/logs \
              ${lib.optionalString config.services.garnixServer.provisionServerPool "--provision-server-pool"}
        '';
      };
      unitConfig = {
        StartLimitIntervalSec = 10;
      };
    };

    systemd.services.frontend = {
      description = "Garnix NextJS webapp";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        User = config.users.users.garnix.name;
        RestartSec = 1;
        Restart = "always";
        KillSignal = "SIGINT";
        Environment = [
          "PORT=${toString config.services.frontend.port}"
          "HOSTNAME=127.0.0.1"
        ];
        ExecStart = ''
          ${flakePackages.frontend_default}/bin/garnix-frontend
        '';
      };
    };

    services = {
      garnixServer = {
        s3Cache = lib.mkMerge [
          (lib.mkIf config.garnix.devMode.enable {
            publicBucket = "test-public";
            publicBaseUrl = "https://pub-aed3ff3b65d444b3aeee39d6ea1767b0.r2.dev";
            privateBucket = "test-private";
            host = "79e0f6a031ca6d9650034b607922ba45.r2.cloudflarestorage.com";
          })
          (lib.mkIf (!config.garnix.devMode.enable) {
            publicBucket = "prod-public";
            publicBaseUrl = "https://garnix-cache.com";
            privateBucket = "prod-private";
            host = "79e0f6a031ca6d9650034b607922ba45.r2.cloudflarestorage.com";
          })
        ];
      };

      nginx = lib.mkIf config.services.garnixServer.enableNginx {
        enable = true;
        recommendedProxySettings = true;
        recommendedOptimisation = true;
        recommendedGzipSettings = true;
        proxyTimeout = "600s";
        appendConfig = ''
          worker_processes auto;
          worker_rlimit_nofile 2048;
        '';
        eventsConfig = ''
          worker_connections 1024;
        '';
        virtualHosts."garnix.io" = {
          default = true;
          forceSSL = !config.garnix.devMode.enable;
          enableACME = !config.garnix.devMode.enable;
          locations = {
            "/api".proxyPass = "http://127.0.0.1:${toString config.services.garnixServer.port}";
            # The web terminal (/api/terminal/<serverId>) is a websocket; nginx
            # only proxies the upgrade with the Upgrade/Connection headers set.
            # The endpoint authenticates the garnix session + server ownership
            # in-app (see Garnix.API.Terminal); when fronting the API with an
            # additional auth gate (oauth2-proxy/Authentik or similar), keep
            # /api/terminal behind that gate like the rest of /api — never add it
            # to a bypass/allow list. See docs/web-terminal.md.
            "/api/terminal/" = {
              proxyPass = "http://127.0.0.1:${toString config.services.garnixServer.port}";
              proxyWebsockets = true;
            };
            "@frontend".proxyPass = "http://127.0.0.1:${toString config.services.frontend.port}";
            "/" = {
              root = "${flakePackages.frontend_default}/public";
              tryFiles = "$uri @frontend";
            };
          };
        };
        virtualHosts."api.garnix.io" = {
          default = false;
          forceSSL = !config.garnix.devMode.enable;
          enableACME = !config.garnix.devMode.enable;
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString config.services.garnixServer.port}/api/";
            extraConfig = ''
              if ($http_origin ~* "^https://(app\.)?garnix\.io$") {
                add_header Access-Control-Allow-Origin "$http_origin";
              }
            '';
          };
        };
      };

      journald.extraConfig = ''
        SystemMaxUse=${config.services.garnixServer.journaldMaxUse}
        SystemMaxFiles=1000
      '';
    };

    sops.secrets = lib.mkIf config.garnix.manageSecretsWithSops {
      database-password = {
        mode = "0440";
        group = config.users.users.garnix.name;
      };
      github_webhook_secret = {
        mode = "0440";
        group = config.users.users.garnix.name;
      };
      github_client_secret = {
        mode = "0440";
        group = config.users.users.garnix.name;
      };
      github_client_id = {
        mode = "0440";
        group = config.users.users.garnix.name;
      };
      github_app_id = {
        mode = "0440";
        group = config.users.users.garnix.name;
      };
      github_app_pk = {
        mode = "0440";
        group = config.users.users.garnix.name;
      };
      garnix_server_remote_builder_ssh = {
        mode = "0400";
        group = config.users.users.garnix.name;
      };
      garnix_server_remote_builder_ssh_garnix = {
        mode = "0400";
        owner = config.users.users.garnix.name;
        key = "garnix_server_remote_builder_ssh";
      };
      opensearch-garnix = {
        mode = "0400";
        owner = config.users.users.garnix.name;
      };
      repo-secrets-key = {
        mode = "0400";
        owner = config.users.users.garnix.name;
      };
      repo-secrets-key-pub = {
        mode = "0400";
        owner = config.users.users.garnix.name;
      };
      prometheus-node-exporter-1 = {
        mode = "0400";
        owner = config.users.users.garnix.name;
      };
      # This key was generated by `Servant.Auth.Server.writeKey`.
      "garnix-jwt-key" = {
        mode = "0400";
        owner = config.users.users.garnix.name;
      };
      "garnix_server_ssh_hosting" = {
        mode = "0400";
        owner = config.users.users.garnix.name;
      };
      garnix_action_runner_ssh = {
        mode = "0400";
        owner = config.users.users.garnix.name;
      };
      "s3-cache-access-key-id" = {
        mode = "0400";
        owner = config.users.users.garnix.name;
      };
      "s3-cache-secret-access-key" = {
        mode = "0400";
        owner = config.users.users.garnix.name;
      };
      "cache-priv-key" = {
        mode = "0400";
        owner = config.users.users.garnix.name;
      };
    };

    users.users.garnix = {
      group = "garnix";
      extraGroups = [ config.users.groups.keys.name ];
      isNormalUser = true;
      description = "Garnix server user";
    };
    users.groups.garnix = { };

    garnix.killRogueNixProcesses = false;
  };
}
