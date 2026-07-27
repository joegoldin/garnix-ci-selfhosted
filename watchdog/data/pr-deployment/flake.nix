{
  # PR-deployment watchdog fixture (Garnix.Watchdog.Checks.prDeploymentCheck):
  # pushed hourly to a test-forge branch, deployed as an `on-pull-request`
  # server, and polled over http — the response body must match ./date. See
  # examples/hello-server/flake.nix for the annotated version of this same
  # nix-native `garnix.server` shape.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    garnix-ci.url = "github:joegoldin/garnix-ci-selfhosted";
  };
  outputs =
    { nixpkgs, garnix-ci, ... }:
    {
      nixosConfigurations.watchdog-pr-deployment-server =
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            garnix-ci.nixosModules.garnix-guest
            ({ pkgs, ... }:
              {
                garnix.server.deployment = {
                  type = "on-pull-request";
                };
                services.nginx =
                  let
                    root = pkgs.writeTextFile {
                      name = "index";
                      destination = "/index.html";
                      text = pkgs.lib.removeSuffix "\n" (builtins.readFile ./date);
                    };
                  in
                  {
                    enable = true;
                    virtualHosts.default = {
                      root = "${root}";
                    };
                  };
              })
          ];
        };
    };
}
