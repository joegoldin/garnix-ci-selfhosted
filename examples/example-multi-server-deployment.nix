{ self, overlays, flakeInputs }: {
  nixosConfigurations = {
    exampleGarnixServer = flakeInputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit flakeInputs;
        flakePackages = self.packages.x86_64-linux;
      };
      modules = [
        { nixpkgs.overlays = overlays; }
        ../nix/modules
        {
          fileSystems."/".device = "foo";
          boot.loader.systemd-boot.enable = true;
          system.stateVersion = "25.11";
          # TODO: move into garnix.garnixServer.enable
          services.garnixServer = {
            enable = true;
            opensearchUrl = "http://exampleOpenSearch/_msearch";
            testFeatures = [ "DevApi" ];
          };
          garnix = {
            devMode.enable = true;
            fluent-bit.enable = true;
            opensearch.fqdn = "exampleOpenSearch";
            database.fqdn = "exampleDb";
            monitoring-client.nodeId = "garnix-server1";
            ipv6Address = "TODO";
          };
        }
      ];
    };

    exampleDb = flakeInputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit flakeInputs;
        flakePackages = self.packages.x86_64-linux;
      };
      modules = [
        { nixpkgs.overlays = overlays; }
        ../nix/modules
        {
          fileSystems."/".device = "foo";
          boot.loader.systemd-boot.enable = true;
          system.stateVersion = "25.11";
          garnix = {
            devMode.enable = true;
            monitoring-client.nodeId = "db1";
            opensearch.fqdn = "exampleOpenSearch"; # TODO (should this be DRY'd up?)
            database = {
              enable = true;
              fqdn = "exampleDb"; # TODO: is this still required?
              allowedIPs = [ "0.0.0.0/0" ];
            };
          };
        }
      ];
    };

    exampleOpenSearch = flakeInputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit flakeInputs;
        flakePackages = self.packages.x86_64-linux;
      };
      modules = [
        { nixpkgs.overlays = overlays; }
        ../nix/modules
        ({ lib, config, ... }: {
          fileSystems."/".device = "foo";
          boot.loader.systemd-boot.enable = true;
          system.stateVersion = "25.11";
          garnix = {
            devMode.enable = true;
            monitoring-client.nodeId = "opensearch1";
            ipv6Address = "TODO";
            opensearch = {
              enable = true;
              fqdn = "exampleOpenSearch";
              dashboards.enable = true;
              isSingleNode = true;
              # Should be the public IP address of this opensearch node, this configures it to work with nixos-compose:
              bindIP = (lib.head config.networking.interfaces.eth1.ipv4.addresses).address;
            };
          };
        })
      ];
    };
  };
}
