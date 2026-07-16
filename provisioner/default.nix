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
}
