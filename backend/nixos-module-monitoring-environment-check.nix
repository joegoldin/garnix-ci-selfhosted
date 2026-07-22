{ flakeInputs, pkgs, system }:
let
  dummyPackage = name: pkgs.writeShellScriptBin name "exit 0";
  testSystem = flakeInputs.nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = {
      inherit flakeInputs;
      flakePackages = {
        backend_garnix = dummyPackage "server";
        backend_migrate = dummyPackage "sqitch";
        backend_postgres = dummyPackage "psql";
        frontend_default = dummyPackage "garnix-frontend";
      };
    };
    modules = [
      ../nix/modules/self-hosted.nix
      {
        system.stateVersion = "25.11";
        garnix.manageSecretsWithSops = false;
        garnix.database = {
          enable = false;
          fqdn = "database.invalid";
        };
        services.garnixServer = {
          enable = true;
          enableNginx = false;
          opensearchUrl = "http://127.0.0.1:9200/_msearch";
          monitoringBuilders = [
            {
              name = "test-builder";
              url = "http://127.0.0.1:9100/metrics";
              systems = [ "x86_64-linux" ];
              maxJobs = 2;
            }
          ];
        };
      }
    ];
  };
  unitFile = pkgs.writeText "garnixServer.service" testSystem.config.systemd.units."garnixServer.service".text;
  expected = ''Environment="GARNIX_MONITORING_BUILDERS=[{\"max_jobs\":2,\"name\":\"test-builder\",\"systems\":[\"x86_64-linux\"],\"url\":\"http://127.0.0.1:9100/metrics\"}]"'';
in
pkgs.runCommand "nixos-module-monitoring-environment" { inherit unitFile; } ''
  grep -F -- '${expected}' "$unitFile"
  touch "$out"
''
