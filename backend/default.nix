{ pkgs
, lib
, system
, flakeInputs
, ...
}:
let
  secretSetup = ''
    SOPS_AGE_KEY=$(${lib.getExe pkgs.ssh-to-age} -private-key -i ${../nix/data/ssh-key-for-local-dev-secrets})
    export SOPS_AGE_KEY
  '';
  dbSetup = ''
    if test -z "$DB_DIR"; then
      echo Set \$DB_DIR before 'dbSetup'
      exit 1
    fi
    mkdir -p "$DB_DIR"
    export PGDATA=$DB_DIR/test
    export PGHOST=$DB_DIR/test
    export PGPORT=9178
    export PGUSER=garnix
    export PGPASSWORD=garnix
    export PGDATABASE=garnix
    # For postgresql-typed
    export TPG_HOST=$PGHOST
    export TPG_DB=$PGDATABASE
    export TPG_USER=$PGUSER
    export TPG_PASS=$PGPASSWORD
    export TPG_SOCK=$PGHOST"/.s.PGSQL."$PGPORT
  '';
  garnixRuntimeDependencies = [
    pkgs.util-linux
    pkgs.git
    pkgs.nix
    pkgs.openssh
    pkgs.coreutils-full
    pkgs.bubblewrap
    pkgs.nettools
    flakeInputs.comment.packages.${system}.default
    pkgs.bzip2
    pkgs.age
    pkgs.xz
    pkgs.rsync
  ];
  migrate = pkgs.callPackage ../nix/packages/migrate.nix { };
  postgres = pkgs.postgresql_18;
  db = pkgs.callPackage ../nix/packages/db.nix {
    inherit migrate postgres;
  };
  cabalInstall = pkgs.haskellPackages.cabal-install.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ../nix/patches/cabal-install-hackage-root-key.patch
    ];
  });
  garnixTestDependencies = [
    db
    pkgs.ps
    pkgs.which
    pkgs.bash
    pkgs.sops
    pkgs.mercurial
    pkgs.curl
    pkgs.garage
    pkgs.psmisc # for `fuser` in specs
  ];
  garnixDevDependencies = [
    (pkgs.haskell-language-server.override { supportedGhcVersions = [ "967" ]; })
    (pkgs.haskellPackages.ghc.withPackages (p: p.garnix.getBuildInputs.haskellBuildInputs))
    pkgs.ghcid
    cabalInstall
    pkgs.haskellPackages.cabal2nix
    pkgs.haskellPackages.hlint
    pkgs.haskellPackages.hpack
    pkgs.haskellPackages.ormolu
  ];
in
rec {
  packages = {
    inherit postgres migrate;
    garnix =
      pkgs.runCommand "garnix"
        {
          nativeBuildInputs = [ pkgs.makeWrapper ];
        }
        ''
          mkdir -p $out/bin
          cp ${packages.garnixHaskellPackage}/bin/server $out/bin
          wrapProgram "$out/bin/server" \
              --set EMPTY_DIR ${../nix/data/emptyDir} \
              --prefix PATH : ${pkgs.lib.makeBinPath garnixRuntimeDependencies}
        '';
    garnixHaskellPackage =
      let
        src =
          with lib.fileset;
          toSource {
            root = ./..;
            fileset =
              difference
                (unions [
                  ./.
                  ../flake.lock
                ])
                (unions [
                  ./default.nix
                  ./nixos-module.nix
                ]);
          };
      in
      pkgs.haskell.lib.overrideCabal pkgs.haskellPackages.garnix (old: {
        buildDepends = (old.buildDepends or [ ]) ++ [ db ];
        inherit src;
        prePatch = ''
          cd backend/
        '';
        preBuild = ''
          ${old.preBuild or ""}
          export HOME=$(pwd)
          DB_DIR=$(pwd)/pg-tmp
          ${dbSetup}
          export EMPTY_DIR=${../nix/data/emptyDir}
          db new
          trap 'db clear' EXIT
        '';
        doCheck = false;
      });
    moduleGraph =
      pkgs.runCommand "moduleGraph.pdf"
        {
          buildInputs = [
            pkgs.haskellPackages.graphmod
            pkgs.graphviz
          ];
        }
        ''
          cp -r ${./.} backend
          graphmod ./backend/exe/Server.hs -i./backend/src \
            | tred \
            | dot -Tpdf > $out
        '';
  };
  checks = {
    cabal-install =
      pkgs.runCommand "cabal-install-test"
        {
          nativeBuildInputs = [ pkgs.python3 ];
        }
        ''
          cd ${./..}
          python3 -m unittest backend/test_cabal_install.py -v
          touch "$out"
        '';
    hlint = pkgs.runCommand "hlint" { buildInputs = [ pkgs.haskell.packages.ghc967.hlint ]; } ''
      cd ${./.}
      hlint src test
      touch $out
    '';
    nixos-module-monitoring-environment = import ./nixos-module-monitoring-environment-check.nix {
      inherit flakeInputs pkgs system;
    };
    check-qualified-imports =
      let
        modulesMustBeQualified = [
          "Garnix.DB"
          "Garnix.Monad.SubProcess.Deprecated"
        ];
        checkNoUnqualifiedImports = module: ''
          echo 'checking for unqualified `${module}`...'
          FOUND=$(grep -r 'import ${module}[^\.]' | grep -v 'qualified' || true)
          if [ -n "$FOUND" ]; then
            echo -e "${module} should always be qualified. Found unqualified imports:\n$FOUND"
            exit 1
          fi
        '';
      in
      pkgs.runCommand "check-qualified-imports"
        {
          buildInputs = [ pkgs.ack ];
        }
        ''
          cd ${./.}
          ${lib.concatLines (lib.map checkNoUnqualifiedImports modulesMustBeQualified)}
          touch $out
        '';
  };
  shellHook = ''
    DB_DIR=$(git rev-parse --show-toplevel)/pg-tmp
    ${dbSetup}
    ${secretSetup}
    export EMPTY_DIR=${../nix/data/emptyDir}
  '';
  devShellInputs = [
    packages.postgres
    pkgs.sqitchPg
  ]
  ++ garnixRuntimeDependencies
  ++ garnixTestDependencies
  ++ garnixDevDependencies;
  nixosModule = import ./nixos-module.nix;
  commands = {
    convertHashids = pkgs.writeShellApplication {
      meta.description = "converts mangled hashids to db ids";
      name = "convertHashids";
      text = ''
        cd backend
        cabal run convert-hashids -- "$@"
      '';
    };

    readModuleSchema = pkgs.writeShellApplication {
      meta.description = "reads a garnix module schema and emits sql";
      name = "readModuleSchema";
      text = ''
        cd backend
        cabal build 1>&2
        withSecrets cabal run read-module-schema -- "$@"
      '';
    };

    specs = pkgs.writeShellApplication {
      meta.description = "runs the backend test suite";
      name = "backend-specs";
      runtimeInputs =
        garnixRuntimeDependencies
        ++ garnixTestDependencies
        ++ [
          (pkgs.haskellPackages.ghc.withPackages (p: p.garnix.getBuildInputs.haskellBuildInputs))
          cabalInstall
          pkgs.jq
        ];
      text = ''
        set -euo pipefail
        tempDir=$(mktemp -d /tmp/garnix-specs.XXXXXXXX)
        cd "$tempDir"
        export HOME="$tempDir/home"
        export XDG_CONFIG_HOME="$HOME/.config"
        export XDG_CACHE_HOME="$HOME/.cache"
        export XDG_STATE_HOME="$HOME/.local/state"
        mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"
        DB_DIR="$tempDir/pg-tmp"
        ${dbSetup}
        db new
        trap 'db clear; rm $tempDir -rf' EXIT

        export EMPTY_DIR=${../nix/data/emptyDir}
        ${secretSetup}
        git config --global user.email "you@example.com"
        git config --global user.name "Your Name"
        git config --global init.defaultBranch main
        cp -r ${./..} src
        chmod a+rwX -R src
        chmod go-rwx src/backend/ssh-key-for-tests

        haveAnyIntegrationSecret=false
        if [[ -n "''${GITHUB_APP_ID:-}" || -n "''${GITHUB_APP_INSTALLATION_ID:-}" || -n "''${GITHUB_APP_PK:-}" ]]; then
          haveAnyIntegrationSecret=true
        fi

        if [[ "$haveAnyIntegrationSecret" == true ]]; then
          if [[ -z "''${GITHUB_APP_ID:-}" || -z "''${GITHUB_APP_INSTALLATION_ID:-}" || -z "''${GITHUB_APP_PK:-}" ]]; then
            echo "backend_specs requires GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, and GITHUB_APP_PK together" >&2
            exit 1
          fi
        else
          actionKey="''${GARNIX_ACTION_PRIVATE_KEY_FILE:-}"
          integrationSecrets="''${GARNIX_BACKEND_SPECS_SECRETS_FILE:-src/secrets/backend-specs-github-app.age}"
          decryptedSecrets="$tempDir/backend-specs-github-app.json"

          if [[ -z "$actionKey" || ! -s "$actionKey" ]]; then
            echo "backend_specs requires its Garnix action private key to decrypt the live GitHub integration-test credentials" >&2
            exit 1
          fi
          if [[ ! -s "$integrationSecrets" ]]; then
            echo "backend_specs integration credential is missing: $integrationSecrets" >&2
            exit 1
          fi
          if ! age --decrypt --identity "$actionKey" --output "$decryptedSecrets" "$integrationSecrets"; then
            echo "backend_specs could not decrypt its live GitHub integration-test credential" >&2
            exit 1
          fi
          chmod 600 "$decryptedSecrets"

          if ! GITHUB_APP_ID=$(jq -er '.github_app_id | select(type == "number" or type == "string") | tostring | select(test("^[1-9][0-9]*$"))' "$decryptedSecrets"); then
            echo "backend_specs integration credential has an invalid github_app_id" >&2
            exit 1
          fi
          if ! GITHUB_APP_INSTALLATION_ID=$(jq -er '.github_app_installation_id | select(type == "number" or type == "string") | tostring | select(test("^[1-9][0-9]*$"))' "$decryptedSecrets"); then
            echo "backend_specs integration credential has an invalid github_app_installation_id" >&2
            exit 1
          fi
          if ! GITHUB_APP_PK=$(jq -er '.github_app_pk | select(type == "string" and (contains("-----BEGIN PRIVATE KEY-----") or contains("-----BEGIN RSA PRIVATE KEY-----")))' "$decryptedSecrets"); then
            echo "backend_specs integration credential has an invalid github_app_pk" >&2
            exit 1
          fi
          export GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PK
        fi

        export GITHUB_WEBHOOK_SECRET="''${GITHUB_WEBHOOK_SECRET:-backend-specs-integration-test}"
        cd src/backend
        cabal configure --ghc-options="-O0"
        cabal run spec -- --fail-on=focused "$@"
      '';
    };
  };
}
