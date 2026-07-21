# Flake sub-directory entry for the provisioner-side tooling. Currently exposes
# the `authentik-provision` helper (see authentik_provision.py) as a flake
# command/package. Imported by flake.nix's per-system section; the NixOS modules
# in this dir (nixos-module.nix, guest-profile.nix, authentik-guard.nix) are
# imported by path elsewhere and are unaffected by this default.nix.
{ lib, pkgs, system, ... }:
let
  guestProfileConfig =
    (lib.nixosSystem {
      inherit system;
      modules = [
        ./guest-profile.nix
        ({ lib, ... }: {
          options.microvm = lib.mkOption {
            type = lib.types.attrs;
            default = { };
          };
          config = {
            garnix.guest.sshPublicKey = "ssh-ed25519 HOSTING hosting";
            garnix.guest.terminalCaPublicKey = "ssh-ed25519 TERMINAL terminal";
            system.stateVersion = "25.11";
          };
        })
      ];
    }).config;
in
{
  commands = {
    authentikProvision = pkgs.writeShellApplication {
      name = "authentik-provision";
      meta.description = "Create/extend an Authentik OIDC app for a garnix deployment and print the garnix.authentik config block";
      runtimeInputs = [
        pkgs.python3
        pkgs.age
      ];
      text = ''
        exec python3 ${./authentik_provision.py} "$@"
      '';
    };
  };
  checks = {
    # Unit tests for the helper: no network (the REST client + age are mocked).
    authentikProvisionTests =
      pkgs.runCommand "authentik-provision-tests" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          cp ${./authentik_provision.py} authentik_provision.py
          cp ${./test_authentik_provision.py} test_authentik_provision.py
          python3 -m unittest test_authentik_provision -v
          touch "$out"
        '';
    provisionerdPortTests =
      pkgs.runCommand "provisionerd-port-tests" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          cp ${./provisionerd.py} provisionerd.py
          cp ${./test_provisionerd_ports.py} test_provisionerd_ports.py
          python3 -m unittest test_provisionerd_ports -v
          touch "$out"
        '';
    guestProfileTerminalCaTests =
      assert lib.hasInfix
        "TrustedUserCAKeys /var/lib/garnix/terminal-ca.pub"
        guestProfileConfig.services.openssh.extraConfig;
      assert builtins.elem
        "d /var/lib/garnix 0755 root root - -"
        guestProfileConfig.systemd.tmpfiles.rules;
      assert builtins.elem
        "C /var/lib/garnix/terminal-ca.pub 0644 root root - /etc/ssh/garnix-hosting-ca.pub"
        guestProfileConfig.systemd.tmpfiles.rules;
      pkgs.runCommand "guest-profile-terminal-ca-tests" { } ''
        touch "$out"
      '';
  };
}
