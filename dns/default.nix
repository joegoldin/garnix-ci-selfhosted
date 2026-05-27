{ pkgs
, flakeInputs
, ...
}:
let
  craneLib = flakeInputs.crane.mkLib pkgs;
  src = craneLib.cleanCargoSource ./.;
  commonArgs = {
    inherit src;
    strictDeps = true;
  };
  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
in
{
  package = craneLib.buildPackage (commonArgs // {
    inherit cargoArtifacts;
    doCheck = false;
  });
  checks = {
    cargo-test = craneLib.cargoTest (commonArgs // {
      inherit cargoArtifacts;
    });
  };
  devShellInputs = with pkgs; [
    cargo
    clippy
    rust-analyzer
    rustc
    rustfmt
  ];
  nixosModule = import ./nixos-module.nix;
}
