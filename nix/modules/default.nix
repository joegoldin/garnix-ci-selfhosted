{ flakeInputs, ... }: {
  imports = [
    ../../backend/nixos-module.nix
    ../../opensearch/nixos-module.nix
    ./common.nix
    ./custom-gc.nix
    ./database.nix
    ./dev-mode.nix
    ./fluent-bit.nix
    ./linux-common.nix
    ./monitoring-client.nix
    ./monitoring.nix
    flakeInputs.sops-nix.nixosModules.sops
  ];
}
