# Nix-native server config: garnix.yaml is the pre-nix contract

**Date:** 2026-07-27
**Status:** Approved design, pending implementation plan

## Principle

**garnix.yaml holds only what the backend must know before evaluating the
flake.** It is fetched as a raw file from the forge — no nix required — so it
is the right home for exactly the decisions that pay off pre-eval:

- `builds` (include/exclude): defines what gets evaluated at all.
- `autoCancelSuperseded`: cancelling a superseded push is only valuable
  before eval/build effort is spent on it.
- `actions`, `artifacts`: declarations that shape the CI run itself.

**Everything describing a server is post-eval information** — the backend
acts on it only after the configuration is built — so it moves into the
module system, inside the `nixosConfiguration` it describes. The legacy
`servers:` yaml section keeps working but becomes optional.

A repo like jkfridge ends up with:

```yaml
# garnix.yaml — complete
autoCancelSuperseded: true
builds:
  include:
    - "packages.x86_64-linux.*"
    - "nixosConfigurations.*"
```

```nix
# inside nixosConfigurations.fridge
garnix.server = {
  deployment = { type = "on-branch"; branch = "main"; machine = "i2x2"; isPrimary = true; };
  domains = [ "..." ];
  exposeSSH = true;
  authorizeDeployerGithubKeys = true;
  backups = {
    paths = [ "/var/lib/jkfridge" ];
    schedule = "daily";
    preBackupCommand = "${pkgs.sqlite}/bin/sqlite3 /var/lib/jkfridge/app.db '.backup /var/lib/jkfridge/app.db.snapshot'";
    postBackupCommand = "${pkgs.coreutils}/bin/rm -f /var/lib/jkfridge/app.db.snapshot";
    preRestoreCommand = "systemctl stop jkfridge";
    postRestoreCommand = "${pkgs.coreutils}/bin/rm -f /var/lib/jkfridge/app.db-wal /var/lib/jkfridge/app.db-shm && ${pkgs.coreutils}/bin/cp /var/lib/jkfridge/app.db.snapshot /var/lib/jkfridge/app.db && systemctl start jkfridge";
  };
  persistence = { enable = true; name = "jkfridge"; };
};
```

## 1. Module surface (fork: `garnix-guest` module)

The `garnix-guest` module (provisioner/guest-profile.nix, exported as
`nixosModules.garnix-guest`) grows options under the existing
`garnix.server.*` namespace — merging cleanly with garnix-lib's
`persistence`/`isVM`/`enable` subtree (distinct attr names, standard module
merging). The schema mirrors the yaml `ServerSection` one-to-one:

- `deployment` (nullable submodule): `type` (`"on-branch"` | `"on-pull-request"`),
  `branch` (str, on-branch only), `machine` (str tier, default `"i1x2"` to
  match the backend default), `isPrimary` (bool, default false). A config
  with `deployment = null` (default) is never deployed — buildable configs
  that aren't servers stay exactly as today.
- `domains` ([str], default []), `exposeSSH` (bool, false),
  `authorizeDeployerGithubKeys` (bool, false), `authorizedSSHKeys` ([str], []),
  `ports` (list of `{ name, port, type }`), `applicationLog` (nullable
  `{ enable, path }`), `backups` (nullable submodule with `paths` (non-empty
  [str], absolute, not `/` or under `/nix/store`), `schedule`
  (`hourly|daily|weekly|"<N>h"`, default daily), and the four optional hook
  strings). Validation mirrors the yaml codec's rules as module assertions.
- Doc strings on `machine` note that changing the tier of a persistent
  server requires recreating the VM (tier is provisioning-time).

## 2. Closure-pinning via `/etc/garnix/server.json` (the load-bearing detail)

If the backend merely `nix eval`ed hook strings off the built config, a
`${pkgs.sqlite}` reference would NOT be guaranteed present in the guest:
string context only pins store paths when the string lands in a derivation.
Therefore the module renders the full aggregate to the guest itself:

- `environment.etc."garnix/server.json".text = builtins.toJSON cfg.serverSpec;`

This guarantees every store path referenced by any hook ships in the system
closure the deploy copies over, and doubles as on-guest introspection. The
same aggregate is exposed as a read-only option `garnix.server.deploySpec`
(JSON-serializable attrset) for the backend to read.

## 3. Backend discovery (generalizing the persistence eval)

`Build/Package.hs` already `nix eval`s `config.garnix.server.persistence`
on built configs. Generalize: after each successful
`nixosConfigurations.<name>` build, one
`nix eval --json .#nixosConfigurations.<name>.config.garnix.server.deploySpec`
(guarded the same way persistence handles configs that don't import the
module — eval failure / option-missing ⇒ not a nix-declared server).
Decoding reuses the SAME Haskell types the yaml codec produces
(`ServerSection`-equivalent), so everything downstream — deploy planning,
domains validation, backups capture into `servers.backups`, exposeSSH,
persistence — is unchanged.

**Union semantics:** nix-declared servers ∪ legacy yaml `servers:`. The same
`configuration` name declared in both is a **hard error** with a clear
message naming both sources — no silent precedence.

## 4. garnix-lib fork: `enable` defaults true

`garnix.server.enable` becomes `default = true` (importing the module means
this config is a garnix server; same reasoning as the `isVM = true` default
that landed 2026-07-27). Assertions gated on `enable` are unchanged; setting
`enable = false` still opts a config out entirely.

## 5. jkfridge migration

- garnix.yaml → the four-line version above (drop `servers:` wholesale).
- flake.nix's fridge config gains the `garnix.server` block (with real
  values), hooks switch to store-path binaries, and
  `environment.systemPackages = [ pkgs.sqlite ]` is deleted from
  nix/module.nix (the hook carries its own binary).
- Behavior must be byte-equivalent at the deploy layer: same
  `servers.backups` jsonb capture, same domains, same persistence — verified
  by comparing the deploy-planned values before/after.

## 6. Compatibility, docs, tests

- Legacy yaml `servers:` parsing stays indefinitely; no deprecation in this
  change. Other repos are untouched.
- README + cookbook lead with the principle: *"needs to be known before nix
  runs → garnix.yaml; describes the server → the server's own module."*
- Config-schema golden regenerated (yaml schema unchanged except doc note).
- Tests: module-level eval specs for the new options + assertions
  (skipAuthPaths-style rendered-config proofs, incl. a store-path hook
  appearing in both `/etc/garnix/server.json` and the closure); backend
  specs for deploySpec decoding, the union, and the duplicate-declaration
  error; existing deploy specs keep covering the yaml path.

## Out of scope

- Moving `actions`/`artifacts` into the flake (CI-run-shaped; revisit only
  if the yaml ever feels heavy again).
- Any deprecation of the yaml `servers:` section.
- PR-deploy parity beyond what `deployment.type = "on-pull-request"`
  already implies (it reuses the existing PR-deploy machinery).
