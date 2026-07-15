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
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
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
          # `return 200 "..."` defaults to Content-Type application/octet-stream
          # (browsers download it), so set an explicit HTML type.
          services.nginx.virtualHosts."_".locations."/".extraConfig = ''
            default_type "text/html; charset=utf-8";
            return 200 "<!doctype html><h1>hello from garnix hosting</h1>";
          '';
        }
      ];
    };

    # Same page, locked behind Authentik login via garnix-authentik. Add a
    # server entry above (configuration = "hello-locked") to deploy it, and fill
    # in the Authentik OIDC details. See docs/authentik-cookbook.md.
    nixosConfigurations.hello-locked = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        microvm.nixosModules.microvm
        garnix-ci.nixosModules.garnix-guest
        garnix-ci.nixosModules.garnix-authentik
        {
          garnix.guest.sshPublicKey = "<YOUR HOSTING PUBLIC KEY>";
          garnix.authentik = {
            enable = true;
            publicUrl = "https://hello-locked.main.<repo>.<owner>.<hostingDomain>";
            issuerUrl = "https://<authentik-host>/application/o/hello-locked/";
            clientId = "<oidc client id>";
            clientSecretAge = ''
              -----BEGIN AGE ENCRYPTED FILE-----
              <age ciphertext of the client secret, encrypted to the repo key>
              -----END AGE ENCRYPTED FILE-----
            '';
            allowedGroups = [ "hello-locked-users" ]; # omit to gate on entitlements only
            upstream = "127.0.0.1:8080";
          };
          # The actual app on :8080, behind the gate (the module owns :80).
          services.nginx.enable = true;
          services.nginx.virtualHosts."app" = {
            listen = [ { addr = "127.0.0.1"; port = 8080; } ];
            locations."/".extraConfig = ''
              default_type "text/html; charset=utf-8";
              return 200 "<!doctype html><h1>locked hello — you are authenticated</h1>";
            '';
          };
        }
      ];
    };
  };
}
