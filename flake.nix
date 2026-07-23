{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05-small";

    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";

    treetop = {
      url = "github:soenkehahn/treetop";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
        crane.follows = "crane";
      };
    };

    crane.url = "github:ipetkov/crane";

    comment = {
      url = "github:garnix-io/comment";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
        crane.follows = "crane";
      };
    };

    cradle = {
      url = "github:garnix-io/cradle";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    terms-and-conditions = {
      url = "github:garnix-io/terms-and-conditions";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    flakeInputs@{ self
    , nixpkgs
    , flake-utils
    , sops-nix
    , cradle
    , treefmt-nix
    , ...
    }:
    let
      overlays = [
        (outerFinal: outerPrev: {
          haskellPackages =
            with outerPrev.haskell.lib;
            outerPrev.haskell.packages.ghc967.override {
              overrides = final: prev: {
                hashids = prev.hashids.overrideAttrs (old: {
                  meta = old.meta // {
                    broken = false;
                  };
                });
                generic-random = prev.callPackage ./nix/packages/generic-random.nix { };
                HDBC = prev.callPackage ./nix/packages/HDBC.nix { };
                servant-github-webhook = prev.callPackage ./nix/packages/servant-github-webhook.nix { };
                generics-eot = prev.callPackage ./nix/packages/generics-eot.nix { };
                iso-deriving = prev.callPackage ./nix/packages/iso-deriving.nix { };
                github-app = prev.callPackage ./nix/packages/github-app.nix { };
                github-webhooks = prev.callPackage ./nix/packages/github-webhooks.nix { };
                oauth2-simple = prev.callPackage ./nix/packages/oauth2-simple.nix { };
                cradle = cradle.lib.${outerPrev.stdenv.hostPlatform.system}.mkCradle final;
                garnix =
                  (dontHaddock (
                    disableLibraryProfiling (
                      disableExecutableProfiling (final.callPackage ./nix/packages/garnix.nix { })
                    )
                  )).overrideAttrs
                    (old: { });
              };
            };
        })
        (final: prev: {
          opensearch-dashboards = final.callPackage ./nix/packages/opensearch-dashboards/default.nix { };

          # See https://github.com/NixOS/nixpkgs/issues/319323
          opensearch = prev.opensearch.overrideAttrs (old: {
            # Workaround for packaging bug (deleting opensearch-cli breaks
            # opensearch-plugin/opensearch-keystore command)
            installPhase = builtins.replaceStrings
              [ "rm $out/bin/opensearch-cli\n" ]
              [ "" ]
              old.installPhase;
          });
        })
      ];
    in
    flake-utils.lib.eachDefaultSystem
      (
        system:
        let
          pkgs = import nixpkgs { inherit system overlays; };
          inherit (nixpkgs) lib;
          namespace = prefix: attrSet: lib.mapAttrs' (name: value: { name = "${prefix}_${name}";inherit value; }) attrSet;
          subDirInputs = {
            inherit system pkgs flakeInputs self;
            inherit (nixpkgs) lib;
          };

          treefmt = import ./nix/treefmt.nix subDirInputs;
          backend = import ./backend subDirInputs;
          frontend = import ./frontend subDirInputs;
          frontend-age-wasm = import ./frontend/age-wasm subDirInputs;
          examples = import ./examples subDirInputs;
          provisioner = import ./provisioner subDirInputs;
        in
        {
          apps = lib.mapAttrs
            (_: drv: {
              type = "app";
              program = lib.getExe drv;
              meta.description = drv.meta.description;
            })
            (namespace "backend" backend.commands //
            namespace "examples" examples.commands //
            namespace "provisioner" provisioner.commands
            );

          checks =
            namespace "backend" backend.checks //
            namespace "frontend" frontend.checks //
            namespace "frontend" (namespace "ageWasm" frontend-age-wasm.checks) //
            namespace "provisioner" provisioner.checks //
            {
              opensearch-package =
                self.nixosConfigurations.exampleOpenSearch.config.services.opensearch.package;
            };

          packages =
            namespace "backend" backend.packages //
            namespace "frontend" frontend.packages //
            namespace "frontend" (namespace "ageWasm" frontend-age-wasm.packages) //
            namespace "provisioner" provisioner.commands;

          formatter = treefmt.wrapper;

          devShells.default = pkgs.mkShell {
            inherit (backend) shellHook;
            buildInputs = [
              pkgs.just
              pkgs.nil
              pkgs.nix
              (pkgs.callPackage ./nix/packages/withSecrets.nix { })
            ]
            ++ backend.devShellInputs
            ++ frontend.devShellInputs;
          };
        }
      )
    // {
      nixosConfigurations =
        (import ./examples/example-multi-server-deployment.nix {
          inherit self overlays flakeInputs;
        }).nixosConfigurations
        # The action-runner VM the backend spec suite boots (Garnix.Action).
        // (import ./nix/tests/action-runner-vm.nix { inherit flakeInputs; }).nixosConfigurations;
      nixosModules = {
        self-hosted = import ./nix/modules/self-hosted.nix;
        # Complete profile for garnix-hosted microVM guests. It carries the
        # pinned microvm.nix module as well as the Garnix guest conventions, so
        # consuming repositories need only this one import.
        garnix-guest = {
          imports = [
            flakeInputs.microvm.nixosModules.microvm
            ./provisioner/guest-profile.nix
          ];
        };
        # Optional: lock a deployed server behind Authentik/OIDC (oauth2-proxy
        # + nginx forward-auth gate on :80). Import into a deployed config and
        # set `garnix.authentik.*`. See provisioner/authentik-guard.nix.
        garnix-authentik = import ./provisioner/authentik-guard.nix;
      };
      # Mandatory for self-hosted consumers: opensearch/nixos-module.nix's
      # dashboards.package option defaults to pkgs.opensearch-dashboards,
      # which only exists via this overlay (nix/packages/opensearch-dashboards);
      # the overlay also carries a workaround for the opensearch packaging bug
      # https://github.com/NixOS/nixpkgs/issues/319323 that opensearch/nixos-module.nix's
      # own opensearch package override builds on top of.
      overlays.default = nixpkgs.lib.composeManyExtensions overlays;
    };
}
