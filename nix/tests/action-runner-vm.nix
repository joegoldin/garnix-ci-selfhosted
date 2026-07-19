# The action-runner VM the spec suite boots for the Garnix.Action tests:
# Garnix.TestHelpers.NixosVmScripts builds
# `.#nixosConfigurations.action-runner2.config.system.build.vm` and ActionSpec
# sshes in as action-runner@localhost (port-forwarded via QEMU_NET_OPTS) with
# the committed backend/dev-action-runner-ssh-key. Upstream had an internal
# action-runner2 config that didn't survive the open-source import; this
# reconstructs it on top of the self-host runner module, so the Action specs
# exercise the same bubblewrap runner erdtree runs in production.
{ flakeInputs }: {
  nixosConfigurations.action-runner2 = flakeInputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      "${flakeInputs.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
      ../modules/action-runner.nix
      ({ pkgs, ... }: {
        garnix.actionRunner = {
          enable = true;
          # Public key of backend/dev-action-runner-ssh-key (dev/test only).
          authorizedKeys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIsTYAj7lBPpDHSXA4kz07+PbvqElJhPG5bLbxYj255Z alex@garnix"
          ];
        };
        services.openssh.enable = true;
        # ActionSpec's readiness probe runs `curl --fail google.com` inside.
        environment.systemPackages = [ pkgs.curl ];
        virtualisation = {
          cores = 2;
          memorySize = 4096;
          # Share the host store (with an overlay): `nix copy` into the VM is
          # cheap and the .vm script needs no store image build.
          writableStore = true;
        };
        system.stateVersion = "25.11";
      })
    ];
  };
}
