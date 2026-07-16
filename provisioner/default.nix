# Flake sub-directory entry for the provisioner-side tooling. Currently exposes
# the `authentik-provision` helper (see authentik_provision.py) as a flake
# command/package. Imported by flake.nix's per-system section; the NixOS modules
# in this dir (nixos-module.nix, guest-profile.nix, authentik-guard.nix) are
# imported by path elsewhere and are unaffected by this default.nix.
{ pkgs, ... }:
{
  commands = {
    authentikProvision = pkgs.writeShellApplication {
      name = "authentik-provision";
      meta.description =
        "Create/extend an Authentik OIDC app for a garnix deployment and print the garnix.authentik config block";
      runtimeInputs = [ pkgs.python3 pkgs.age ];
      text = ''
        exec python3 ${./authentik_provision.py} "$@"
      '';
    };
  };
  checks = {
    # Unit tests for the helper: no network (the REST client + age are mocked).
    authentikProvisionTests = pkgs.runCommand "authentik-provision-tests"
      { nativeBuildInputs = [ pkgs.python3 ]; } ''
      cp ${./authentik_provision.py} authentik_provision.py
      cp ${./test_authentik_provision.py} test_authentik_provision.py
      python3 -m unittest test_authentik_provision -v
      touch "$out"
    '';
  };
}
