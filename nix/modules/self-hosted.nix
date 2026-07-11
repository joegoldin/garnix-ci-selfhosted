# Curated module set for self-hosting garnix CI on an existing NixOS host.
# Deliberately EXCLUDES linux-common.nix, common.nix, monitoring.nix (they
# assume garnix.io's fleet: ACME email, ssh users, monitoring fqdns).
# Consumer must provide _module.args.flakePackages and _module.args.flakeInputs
# (the latter via `specialArgs` on nixosSystem, since it's needed in `imports`
# below).
{ lib, flakeInputs, ... }: {
  imports = [
    ../../backend/nixos-module.nix
    ../../opensearch/nixos-module.nix
    ./custom-gc.nix
    ./database.nix
    ./dev-mode.nix
    ./fluent-bit.nix
    ./monitoring-client.nix
    # Several curated modules declare `sops.secrets = lib.mkIf
    # config.garnix.manageSecretsWithSops { ... }`. Even with that gate false,
    # the module system still requires the `sops` option to exist, so the
    # sops-nix module must be imported unconditionally, same as
    # nix/modules/default.nix does.
    flakeInputs.sops-nix.nixosModules.sops
  ];

  # Stubs for options normally declared in linux-common.nix (not imported here,
  # since it also carries hetzner/fleet-specific config we don't want on an
  # arbitrary self-hosted box). backend/nixos-module.nix and dev-mode.nix set
  # these unconditionally in their `config` bodies, so the option must exist
  # even when its value is never read.
  options.garnix = {
    killRogueNixProcesses = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    ipv4 = lib.mkOption {
      description = "Static ipv4 configuration. If set to null, then DHCP will be used.";
      default = null;
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          address = lib.mkOption { type = lib.types.str; };
          gateway = lib.mkOption { type = lib.types.str; };
          iface = lib.mkOption { type = lib.types.str; };
        };
      });
    };

    ipv6Address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
  };
}
