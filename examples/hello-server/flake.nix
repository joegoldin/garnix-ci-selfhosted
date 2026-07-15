{
  # Minimal user repo for self-hosted garnix server deployments: pushing to
  # `main` deploys nixosConfigurations.hello as a microVM on the garnix host,
  # reachable at https://hello.main.<repo>.<owner>.<hostingDomain>.
  #
  # The two module imports are mandatory: a config missing them would switch
  # the guest to a system whose fstab lacks the microVM volume/share mounts.
  # Set garnix.guest.sshPublicKey to the instance's hosting public key
  # (/var/lib/garnix-provisioner/hosting.pub on the garnix host) or redeploys
  # will lock the backend out of the guest.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
    garnix-ci.url = "github:joegoldin/garnix-ci/self-hosting";
  };
  outputs = { self, nixpkgs, microvm, garnix-ci }: {
    garnix.config.servers = [
      {
        configuration = "hello";
        deployment = {
          type = "on-branch";
          branch = "main";
        };
      }
    ];
    nixosConfigurations.hello = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        microvm.nixosModules.microvm
        garnix-ci.nixosModules.garnix-guest
        {
          garnix.guest.sshPublicKey = "<YOUR HOSTING PUBLIC KEY>";
          services.nginx.enable = true;
          services.nginx.virtualHosts."_".locations."/".return = ''200 "hello from garnix hosting"'';
        }
      ];
    };
  };
}
