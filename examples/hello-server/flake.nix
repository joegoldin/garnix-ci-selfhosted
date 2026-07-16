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
    garnix-ci.url = "github:joegoldin/garnix-ci-selfhosted";
  };
  outputs = { self, nixpkgs, microvm, garnix-ci }: {
    garnix.config.servers = [
      {
        configuration = "hello";
        deployment = {
          type = "on-branch";
          branch = "main";
          # Optional microVM size; omit for the i1x1 default (1 vCPU, 1 GiB).
          # machine = "i2x2";
        };
        # Optional SSH access to the guest's `garnix` user (login-closed and
        # password-auth-off by default). `exposeSSH` only opens a public DNAT
        # port; authorize a login too via the fields below (or reach it over
        # tailscale / ProxyJump without exposeSSH).
        # exposeSSH = true;
        # authorizeDeployerGithubKeys = true;   # your github.com/<user>.keys
        # authorizedSSHKeys = [ "ssh-ed25519 AAAA... me@laptop" ];
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
            # mode defaults to "dedicated" (this app gets its own Authentik
            # provider). For one shared provider across many apps, see the
            # "shared mode" section of docs/authentik-cookbook.md.
            publicUrl = "https://hello-locked.main.<repo>.<owner>.<hostingDomain>";
            issuerUrl = "https://<authentik-host>/application/o/hello-locked/";
            clientId = "<oidc client id>";
            # Committed .age file (encrypted to the repo key); referenced by path,
            # never inline. Create with `age -R repo.pub -a > ...` or the
            # authentik-provision helper.
            clientSecretFile = ./hello-locked-client-secret.age;
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
