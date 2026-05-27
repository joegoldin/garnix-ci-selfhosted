{ pkgs
, ...
}:
let
  onDemandResolver =
    let
      nodejs = pkgs.nodejs;
      npmRoot = ./on-demand-resolver;
      node_modules = pkgs.importNpmLock.buildNodeModules { inherit nodejs npmRoot; };
      bundle = pkgs.runCommand "on-demand-resolver" { buildInputs = [ nodejs ]; } ''
        cp -r ${npmRoot} on-demand-resolver
        cd on-demand-resolver
        chmod -R +w .
        cp -r ${node_modules}/node_modules .
        npm run build
        mkdir -p $out
        cp -r node_modules dist $out
      '';
    in
    {
      package = pkgs.writeShellApplication {
        name = "on-demand-resolver";
        runtimeInputs = [ nodejs ];
        text = "node ${bundle}/dist";
      };
      check = pkgs.runCommand "test-on-demand-resolver" { buildInputs = [ nodejs ]; } ''
        cp -r ${npmRoot} on-demand-resolver
        cd on-demand-resolver
        chmod -R +w .
        cp -r ${node_modules}/node_modules .
        npm test
        touch $out
      '';
    };
in
{
  devShellInputs = with pkgs; [
    go
    gopls
  ];

  packages = {
    onDemandResolver = onDemandResolver.package;
  };

  checks = {
    testOnDemandResolver = onDemandResolver.check;
  };

  nixosModule = ./nixos-module.nix;
}
