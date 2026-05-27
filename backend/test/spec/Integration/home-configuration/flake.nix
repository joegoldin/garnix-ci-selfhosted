{
  description = "A very basic flake";
  inputs.home-manager.url = "github:nix-community/home-manager/release-23.05";

  outputs = { self, home-manager }: {

    homeConfigurations = {
      failing = home-manager.lib.homeManagerConfiguration {
        pkgs = import home-manager.inputs.nixpkgs { system = "x86_64-linux"; };
        modules = [
          ({ pkgs, ... }: {
            home = {
              homeDirectory = null;
              stateVersion = "23.05";
              username = "example";
            };
          })
        ];
      };
      succeeding = home-manager.lib.homeManagerConfiguration {
        pkgs = import home-manager.inputs.nixpkgs { system = "x86_64-linux"; };
        modules = [
          ({ pkgs, ... }: {
            home = {
              homeDirectory = "/tmp/garnix-example";
              stateVersion = "23.05";
              username = "example";
            };
          })
        ];
      };
    };

  };
}
