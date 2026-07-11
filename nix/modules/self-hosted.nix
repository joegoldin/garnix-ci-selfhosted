# Curated module set for self-hosting garnix CI on an existing NixOS host.
# Deliberately EXCLUDES linux-common.nix, common.nix, monitoring.nix (they
# assume garnix.io's fleet: ACME email, ssh users, monitoring fqdns).
#
# CONSUMER CONTRACT — read carefully:
#   * `flakeInputs` MUST be passed via `specialArgs` on nixosSystem
#     (e.g. `specialArgs.flakeInputs = inputs.garnix-ci.inputs;`).
#     `_module.args` is NOT sufficient: `flakeInputs` is dereferenced in
#     `imports` below, which is resolved before `_module.args` exists —
#     using `_module.args.flakeInputs` fails with infinite recursion.
#   * `flakePackages` MAY be passed either way (`specialArgs.flakePackages`
#     or `config._module.args.flakePackages = inputs.garnix-ci.packages.<system>;`),
#     since it is only used inside `config`, never in `imports`.
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
    #
    # WARNING: consumers must NOT also import sops-nix's nixosModules.sops
    # themselves — it is already bundled here. The sops-nix module has no
    # dedupe key, so a second import (in particular from the consumer's own
    # sops-nix flake input, which is a different store path) hard-fails with
    # "option 'sops.gnupg.home' ... is already declared".
    flakeInputs.sops-nix.nixosModules.sops
  ];

  # Stubs for options normally declared in linux-common.nix (not imported here,
  # since it also carries hetzner/fleet-specific config we don't want on an
  # arbitrary self-hosted box). backend/nixos-module.nix and dev-mode.nix set
  # these unconditionally in their `config` bodies, so the option must exist
  # even when its value is never read.
  #
  # Consequence: this module is deliberately INCOMPATIBLE with the fleet
  # module set — importing it alongside linux-common.nix (or common.nix,
  # which pulls it in via nix/modules/default.nix) hard-fails with duplicate
  # declarations of `garnix.ipv4`, `garnix.ipv6Address` and
  # `garnix.killRogueNixProcesses`. Use one or the other, never both.
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
