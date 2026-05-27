{ pkgs, lib, ... }:

let
  # These targets represent the machines our users would deploy
  target = number: { nodes, ... }: {
    networking.firewall.allowedTCPPorts = [ 80 443 ];
    environment.etc."www/index.html" = {
      text = "Hi from target${toString number}";
      mode = "666";
    };
    services.nginx = {
      enable = true;
      virtualHosts."/" = {
        root = "/etc/www";
      };
    };
  };
  nodeExporterURL = nodes: nodes.hostingGateway.garnix.monitoring-client.fqdn;

  common = { nodes, ... }: {
    # This mimics DNS entries. There, we can do wildcards, but in
    # /etc/hosts it's not possible
    networking.extraHosts = ''
      ${nodes.pebble.networking.primaryIPAddress} pebble
      ${nodes.hostingGateway.networking.primaryIPAddress} package.branch.repo.owner.garnix.me
      ${nodes.hostingGateway.networking.primaryIPAddress} ${nodeExporterURL nodes}
      ${nodes.garnixServer.networking.primaryIPAddress} garnix.io
    '';
  };
in
{
  name = "hosting-gateway";
  nodes = {
    pebble = { pkgs, ... }: {
      systemd.services.pebble = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Environment = [ "PEBBLE_VA_NOSLEEP=1" "PEBBLE_VA_ALWAYS_VALID=1" ];
          DynamicUser = true;
          ExecStart = "${pkgs.pebble}/bin/pebble -config ${pkgs.writeText "pebble.json" (builtins.toJSON {
            pebble = {
              listenAddress = "0.0.0.0:14000";
              managementListenAddress = "0.0.0.0:15000";
              certificate = "${pkgs.pebble.src}/test/certs/localhost/cert.pem";
              privateKey = "${pkgs.pebble.src}/test/certs/localhost/key.pem";
            };
          })}";
        };
      };

      networking.firewall.allowedTCPPorts = [ 14000 15000 ];
    };
    hostingGateway = { nodes, config, pkgs, lib, ... }: {
      imports = [ common ];
      garnix = {
        monitoring.monitoredHosts = {
          ${config.networking.hostName} = { };
        };
        monitoring-client = {
          enable = lib.mkForce true;
          fqdn = config.garnix.devMode.certificates.domain;
          nodeId = config.networking.hostName;
          basicAuth = {
            username = "foo";
            passwordFile = "${pkgs.writeText "pwd" "pwd"}";
          };
        };
      };
      garnix.hosting-gateway = {
        enable = true;
        serverMappingEndpoint = "http://${nodes.garnixServer.networking.primaryIPAddress}/api/hosts/traefik";
        pollInterval = 1;
        extraCaddyAcmeConfig = {
          ca = "https://pebble:14000/dir";
          trusted_roots_pem_files = [ "${pkgs.pebble.src}/test/certs/pebble.minica.pem" ];
        };
        garnixOrigin = "http://garnix.io";
      };
    };
    target1 = target 1;
    target2 = target 2;
    garnixServer = { config, nodes, pkgs, lib, ... }: {
      imports = [ common ];
      networking.firewall.allowedTCPPorts = [ 80 443 ];
      networking.extraHosts = ''
        127.0.0.1 ${config.garnix.database.fqdn}
      '';
      garnix.database = {
        enable = true;
      };
      services.garnixServer = {
        enable = true;
        testFeatures = [ ];
        provisionServerPool = false;
      };
    };
    client = {
      imports = [ common ];
    };
  };
  testScript = { nodes, ... }:
    let
      addServer =
        ipv4:
        let
          sql = pkgs.writeText "add-server.sql" ''
            do $$ declare build_id integer; begin
              insert into builds
                (
                  repo_user,
                  repo_name,
                  git_commit,
                  package,
                  branch,
                  package_type,
                  req_user,
                  repo_is_public
                )
                values
                (
                  'owner',
                  'repo',
                  'aaaaaaa',
                  'package',
                  'branch',
                  'nixosConfiguration',
                  'owner',
                  true
                )
                returning id into build_id;

              insert into servers
                (
                  configuration_build_id,
                  server_tier,
                  hetzner_id,
                  ipv4,
                  ipv6,
                  ready_at
                )
                values
                (
                  build_id,
                  'server-tier',
                  123,
                  '${ipv4}',
                  'ipv6',
                  now()
                );
            end $$;
          '';
        in
        lib.getExe (
          pkgs.writeShellApplication {
            name = "update-db";
            runtimeInputs = [
              pkgs.curl
              pkgs.postgresql
            ];
            text = ''
              # Wait for garnix server to be up to ensure migrations have finished
              while ! curl --silent http://localhost:${toString nodes.garnixServer.services.garnixServer.port}/api/health/check; do
                sleep 1
              done
              PGPASSWORD=$(cat /run/secrets/database-password) psql \
                --host=localhost \
                --user=garnix \
                --port=${toString nodes.garnixServer.garnix.database.dbPort} \
                --file="${sql}" \
                ${nodes.garnixServer.garnix.database.dbName}
            '';
          }
        );
    in
    ''
      pebble.start()

      # Not waiting for pebble to be up before caddy can cause caddy to fail to
      # get the initial certificates causing node exporter tests to be flaky:
      pebble.wait_for_unit("pebble.service")

      start_all()

      hostingGateway.wait_for_unit("multi-user.target")
      hostingGateway.wait_for_unit("traefik.service")
      hostingGateway.wait_for_unit("caddy.service")
      hostingGateway.wait_for_unit("caddyOnDemandResolver.service")
      target1.wait_for_unit("multi-user.target")
      target1.wait_for_unit("nginx.service")
      target2.wait_for_unit("multi-user.target")
      target2.wait_for_unit("nginx.service")
      garnixServer.wait_for_unit("multi-user.target")
      hostingGateway.wait_for_unit("prometheus-node-exporter.service")

      hostingGateway.wait_until_succeeds("nc localhost 80 -z")

      client.succeed("curl --cacert ${pkgs.pebble.src}/test/certs/pebble.minica.pem https://pebble:15000/roots/0 > /tmp/pebble-root.pem")

      with subtest("Redirects http to https"):
        output = client.succeed("curl --head http://package.branch.repo.owner.garnix.me")
        assert "308 Permanent Redirect" in output, f"expected 308 redirect in: {output}"
        assert "Location: https://package.branch.repo.owner.garnix.me/" in output, f"expected redirect to https: {output}"

      with subtest("Wait for CA certificate to be valid"):
        output = client.fail("curl --no-progress-meter --cacert /tmp/pebble-root.pem https://package.branch.repo.owner.garnix.me 2>&1")
        assert "TLS connect error" in output, f"expected: TLS connect error in: {output}"

      with subtest("Adding an initial target works"):
        garnixServer.succeed("${addServer nodes.target1.networking.primaryIPAddress}")
        client.wait_until_succeeds("curl --no-progress-meter --cacert /tmp/pebble-root.pem --fail-with-body https://package.branch.repo.owner.garnix.me | grep -F 'Hi from target1'", timeout=30)

      with subtest("Changing the target works"):
        garnixServer.succeed("${addServer nodes.target2.networking.primaryIPAddress}")
        client.wait_until_succeeds("curl --no-progress-meter --cacert /tmp/pebble-root.pem --fail-with-body https://package.branch.repo.owner.garnix.me | grep -F 'Hi from target2'", timeout=30)

      with subtest("Proxies and auth-protects the node exporter"):
        output = client.succeed("curl --no-progress-meter -o /dev/null -w '%{http_code}' --cacert /tmp/pebble-root.pem https://${nodeExporterURL nodes}", timeout=120)
        assert output == "401", f"expected status code 401 but got {output}"
        client.succeed("curl --no-progress-meter --cacert /tmp/pebble-root.pem -u foo:pwd -iv https://${nodeExporterURL nodes}", timeout=30)
    '';
}
