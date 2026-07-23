# Durable Terminal CA Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the dedicated web-terminal CA trusted across repository NixOS activation, guest reboot, and CA rotation.

**Architecture:** The guest profile trusts a durable public file at `/var/lib/garnix/terminal-ca.pub` and seeds it once from the provisioner-injected `/etc` file. Before every activation, the backend derives the CA public key on erdtree and streams it over the existing hosting-key SSH channel; activation aborts if that handoff fails.

**Tech Stack:** NixOS modules, Haskell, OpenSSH, Hspec, Nix flake checks

## Global Constraints

- The terminal CA private key never leaves erdtree and never appears in process arguments or logs.
- Public key delivery uses SSH standard input.
- The destination is `/var/lib/garnix/terminal-ca.pub`, owned by `root:root`, mode `0644`.
- Public-key delivery completes before `switch-to-configuration` on new deployments and persistent redeployments.
- Preserve the user's untracked `docs/plans/2026-07-20-garnix-hosting-hardening.md`.
- Do not deploy erdtree; stop after pushing the fork and dotfiles input bump.

---

### Task 1: Guest profile trusts the durable terminal CA

**Files:**
- Modify: `provisioner/default.nix`
- Modify: `provisioner/guest-profile.nix`

**Interfaces:**
- Consumes: `garnix.guest.terminalCaPublicKey`
- Produces: `/var/lib/garnix/terminal-ca.pub` seed and `TrustedUserCAKeys /var/lib/garnix/terminal-ca.pub`

- [ ] **Step 1: Add a failing Nix evaluation check**

In `provisioner/default.nix`, evaluate `guest-profile.nix` with a stub `microvm` option and assert:

```nix
let
  guestProfileConfig =
    (lib.nixosSystem {
      inherit system;
      modules = [
        ./guest-profile.nix
        ({ lib, ... }: {
          options.microvm = lib.mkOption {
            type = lib.types.attrs;
            default = { };
          };
          config = {
            garnix.guest.sshPublicKey = "ssh-ed25519 HOSTING hosting";
            garnix.guest.terminalCaPublicKey = "ssh-ed25519 TERMINAL terminal";
            system.stateVersion = "25.11";
          };
        })
      ];
    }).config;
in
```

Add a check whose assertions require the durable trusted path and both tmpfiles rules:

```nix
guestProfileTerminalCaTests =
  assert lib.hasInfix
    "TrustedUserCAKeys /var/lib/garnix/terminal-ca.pub"
    guestProfileConfig.services.openssh.extraConfig;
  assert builtins.elem
    "d /var/lib/garnix 0755 root root - -"
    guestProfileConfig.systemd.tmpfiles.rules;
  assert builtins.elem
    "C /var/lib/garnix/terminal-ca.pub 0644 root root - /etc/ssh/garnix-hosting-ca.pub"
    guestProfileConfig.systemd.tmpfiles.rules;
  pkgs.runCommand "guest-profile-terminal-ca-tests" { } ''
    touch "$out"
  '';
```

- [ ] **Step 2: Run the check and verify RED**

Run: `nix build .#checks.x86_64-linux.provisioner_guestProfileTerminalCaTests --no-link`

Expected: evaluation fails on the missing durable-path assertion.

- [ ] **Step 3: Implement the guest profile change**

Keep `/etc/ssh/garnix-hosting-ca.pub` as the injected first-boot source, add:

```nix
systemd.tmpfiles.rules = [
  "d /var/lib/garnix 0755 root root - -"
  "C /var/lib/garnix/terminal-ca.pub 0644 root root - /etc/ssh/garnix-hosting-ca.pub"
];
```

Change the OpenSSH directive to:

```text
TrustedUserCAKeys /var/lib/garnix/terminal-ca.pub
```

- [ ] **Step 4: Run the check and verify GREEN**

Run: `nix build .#checks.x86_64-linux.provisioner_guestProfileTerminalCaTests --no-link`

Expected: exit 0.

- [ ] **Step 5: Commit the guest contract**

```bash
git add provisioner/default.nix provisioner/guest-profile.nix
git commit -m "provisioner: persist terminal CA public key"
```

### Task 2: Public-key installer has a pinned privilege boundary

**Files:**
- Modify: `backend/src/Garnix/Types/Keys.hs`
- Modify: `backend/test/spec/Garnix/TypesSpec.hs`

**Interfaces:**
- Produces: `InstallPublicKeyOpts`, `installPublicKey`, `installPublicKeySshArgs`, and `deriveSshPublicKey`
- Consumes: SSH argument list, guest address, SSH user, sudo flag, public key text, target path

- [ ] **Step 1: Add failing argv tests**

Add `installPublicKeySshArgs` examples to `TypesSpec` that require direct root delivery and non-interactive sudo delivery:

```haskell
let opts user sudo =
      InstallPublicKeyOpts
        { publicKey = "ssh-ed25519 TERMINAL terminal",
          ipAddr = "10.111.0.23",
          targetPath = "/var/lib/garnix/terminal-ca.pub",
          sshArgs = ["-i", "/run/secrets/hosting-key"],
          sshUser = user,
          sshSudo = sudo
        }
```

Expected argv ends in:

```haskell
["install", "-D", "-m", "0644", "/dev/stdin", "/var/lib/garnix/terminal-ca.pub"]
```

and includes `sudo -n` only for the `garnix` user.

- [ ] **Step 2: Run targeted Types specs and verify RED**

Run:

```bash
nix develop --command bash -c '
  set -euo pipefail
  DB_DIR=$(mktemp -d /tmp/specdb.XXXXXX)
  export DB_DIR PGDATA=$DB_DIR/test PGHOST=$DB_DIR/test
  export TPG_HOST=$DB_DIR/test TPG_SOCK=$DB_DIR/test/.s.PGSQL.9178
  cleanup() { db clear >/dev/null 2>&1 || true; rm -rf "$DB_DIR"; }
  trap cleanup EXIT
  db new
  cd backend
  cabal run spec -- --match "Types installPublicKeySshArgs"'
```

Expected: compilation fails because `InstallPublicKeyOpts` and `installPublicKeySshArgs` do not exist.

- [ ] **Step 3: Implement the key helpers**

In `Garnix.Types.Keys`, export and implement:

```haskell
data InstallPublicKeyOpts = InstallPublicKeyOpts
  { publicKey :: Text,
    ipAddr :: Text,
    targetPath :: FilePath,
    sshArgs :: [Text],
    sshUser :: Text,
    sshSudo :: Bool
  }

installPublicKeySshArgs :: InstallPublicKeyOpts -> [String]
installPublicKeySshArgs opts =
  (cs <$> sshArgs opts)
    <> [cs (sshUser opts) <> "@" <> cs (ipAddr opts)]
    <> (if sshSudo opts then ["sudo", "-n"] else [])
    <> ["install", "-D", "-m", "0644", "/dev/stdin", targetPath opts]
```

`installPublicKey` runs `ssh` with those arguments and sends `publicKey <> "\n"` on stdin. `deriveSshPublicKey` runs `ssh-keygen -y -f <private-key-path>`, returns stripped non-empty stdout on success, and returns a fixed error without exposing stderr otherwise.

- [ ] **Step 4: Run targeted Types specs and verify GREEN**

Run the same targeted command.

Expected: both direct-root and sudo tests pass.

### Task 3: Backend refreshes the terminal CA before activation

**Files:**
- Modify: `backend/src/Garnix/Hosting/Deploy.hs`
- Modify: `backend/test/spec/Garnix/DeploySpec.hs`

**Interfaces:**
- Consumes: `Env.sshTerminalCaKey`, `deriveSshPublicKey`, `installPublicKey`, `ServerPool.sshArgsFor`
- Produces: `copyTerminalCa :: SshUser -> ServerInfo -> M ()`

- [ ] **Step 1: Add a failing real-guest deployment test**

After deploying a server in `DeploySpec`, derive the expected public key from `view #sshTerminalCaKey`, SSH to the guest with `sshArgsFor`, and assert that `/var/lib/garnix/terminal-ca.pub` equals the derived key:

```haskell
it "deploys the terminal CA public key to the durable guest path" $ do
  let event = defaultEvent
  runTestM $ withContext event $ \repoInfo branch -> do
    commitInfo <- doABuild simpleFlake event repoInfo
    writeMatchingConfig branch (PackageName "default")
    [server] <- rolloutNewServerVersion mempty commitInfo (BranchDeployment branch)
    terminalCaKey <- view #sshTerminalCaKey
    expected <- liftIO (deriveSshPublicKey terminalCaKey) >>= either (error . cs) pure
    (ip, sshArgs) <- sshArgsFor server
    StdoutRaw actual <-
      run $ cmd "ssh"
        & addArgs (sshArgs <> ["root@" <> cs ip, "cat /var/lib/garnix/terminal-ca.pub"])
    liftIO $ T.strip (cs actual) `shouldBe` expected
```

- [ ] **Step 2: Run the targeted deploy spec and verify RED**

Run:

```bash
nix develop --command bash -c '
  set -euo pipefail
  DB_DIR=$(mktemp -d /tmp/specdb.XXXXXX)
  export DB_DIR PGDATA=$DB_DIR/test PGHOST=$DB_DIR/test
  export TPG_HOST=$DB_DIR/test TPG_SOCK=$DB_DIR/test/.s.PGSQL.9178
  cleanup() { db clear >/dev/null 2>&1 || true; rm -rf "$DB_DIR"; }
  trap cleanup EXIT
  db new
  cd backend
  cabal run spec -- --match "deploys the terminal CA public key to the durable guest path"'
```

Expected: FAIL because the durable file is absent.

- [ ] **Step 3: Implement ordered delivery**

Add `copyTerminalCa` to derive the public key, build `InstallPublicKeyOpts`, and throw `OtherError` on derivation or install failure. Call it:

```haskell
copyKeys (SshUser "root") repoInfo serverInfo
copyTerminalCa (SshUser "root") serverInfo <?> "Copying terminal CA public key"
copyClosure (SshUser "root") serverInfo storePath
```

and on persistent redeploy:

```haskell
copyKeys (SshUser "garnix") ...
copyTerminalCa (SshUser "garnix") serverInfo <?> "Copying terminal CA public key"
copyClosure (SshUser "garnix") ...
```

- [ ] **Step 4: Run the targeted deploy and Types specs and verify GREEN**

Repeat the two exact targeted commands from Task 2 Step 2 and Task 3 Step 2.

Expected: both targeted commands exit 0.

- [ ] **Step 5: Commit backend delivery**

```bash
git add backend/src/Garnix/Types/Keys.hs backend/src/Garnix/Hosting/Deploy.hs backend/test/spec/Garnix/TypesSpec.hs backend/test/spec/Garnix/DeploySpec.hs
git commit -m "backend: refresh terminal CA before guest activation"
```

### Task 4: Gate and publish the fork

**Files:**
- Modify: none

- [ ] **Step 1: Run focused and package verification**

```bash
nix build .#checks.x86_64-linux.provisioner_guestProfileTerminalCaTests --no-link
nix build .#checks.x86_64-linux.provisioner_provisionerdPortTests --no-link
nix build .#backend_garnixHaskellPackage --no-link --print-out-paths
nix flake check --no-build
```

- [ ] **Step 2: Audit the committed range and worktree**

Verify the only untracked file is the preserved hardening plan, inspect `git diff origin/main..HEAD`, and run `git diff --check origin/main..HEAD`.

- [ ] **Step 3: Push fork main**

Run: `git push origin main`

Expected: GitHub `main` advances to the backend delivery commit.

### Task 5: Bump, verify, commit, and push dotfiles

**Files:**
- Modify: `/home/joe/dotfiles/flake.lock`

- [ ] **Step 1: Update only the fork input**

Run in `/home/joe/dotfiles`:

```bash
nix flake update garnix-ci
```

Verify `flake.lock` moves `garnix-ci` to the just-pushed fork revision and no other input changes.

- [ ] **Step 2: Build the exact erdtree closure without deploying**

Run:

```bash
NIX_CONFIG="access-tokens = github.com=$(gh auth token)" \
  nix build .#nixosConfigurations.erdtree.config.system.build.toplevel \
  --no-link --print-out-paths
```

Record the resulting store path. Do not call `switch-to-configuration` or `just build-to-erdtree`.

- [ ] **Step 3: Commit and push dotfiles**

```bash
git add flake.lock
git commit -m "flake: bump garnix-ci for durable terminal CA handoff"
git push origin main
```

- [ ] **Step 4: Hand off the rebuild**

Report both pushed commit IDs and the exact expected erdtree toplevel. Wait for the operator to rebuild erdtree before updating `garnix-hello`.
