# Flake sub-directory entry for the provisioner-side tooling. Currently exposes
# the `authentik-provision` helper (see authentik_provision.py) as a flake
# command/package. Imported by flake.nix's per-system section; the NixOS modules
# in this dir (nixos-module.nix, guest-profile.nix, authentik-guard.nix) are
# imported by path elsewhere and are unaffected by this default.nix.
{
  lib,
  pkgs,
  system,
  ...
}:
let
  mkGuestProfileConfig =
    guestConfig:
    (lib.nixosSystem {
      inherit system;
      modules = [
        ./guest-profile.nix
        ({ lib, ... }: {
          options.microvm = lib.mkOption {
            type = lib.types.attrs;
            default = { };
          };
          config = lib.mkMerge [
            {
              garnix.guest.sshPublicKey = "ssh-ed25519 HOSTING hosting";
              garnix.guest.terminalCaPublicKey = "ssh-ed25519 TERMINAL terminal";
              system.stateVersion = "25.11";
            }
            guestConfig
          ];
        })
      ];
    }).config;
  guestProfileConfig = mkGuestProfileConfig { };
  statsHttpStub = pkgs.writeText "garnix-stats-http-stub.py" ''
    import http.server
    import pathlib
    import sys

    status = int(sys.argv[1])
    port = int(sys.argv[2])
    count_path = pathlib.Path(sys.argv[3])
    ready_path = pathlib.Path(sys.argv[4])

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            count_path.write_text(str(int(count_path.read_text()) + 1))
            self.send_response(status)
            self.end_headers()

        def log_message(self, *_args):
            pass

    count_path.write_text("0")
    server = http.server.HTTPServer(("127.0.0.1", port), Handler)
    ready_path.touch()
    server.serve_forever()
  '';
in
{
  commands = {
    authentikProvision = pkgs.writeShellApplication {
      name = "authentik-provision";
      meta.description = "Create/extend an Authentik OIDC app for a garnix deployment and print the garnix.authentik config block";
      runtimeInputs = [
        pkgs.python3
        pkgs.age
      ];
      text = ''
        exec python3 ${./authentik_provision.py} "$@"
      '';
    };
  };
  checks = {
    # Unit tests for the helper: no network (the REST client + age are mocked).
    authentikProvisionTests =
      pkgs.runCommand "authentik-provision-tests" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          cp ${./authentik_provision.py} authentik_provision.py
          cp ${./test_authentik_provision.py} test_authentik_provision.py
          python3 -m unittest test_authentik_provision -v
          touch "$out"
        '';
    provisionerdPortTests =
      pkgs.runCommand "provisionerd-port-tests" { nativeBuildInputs = [ pkgs.python3 ]; }
        ''
          cp ${./provisionerd.py} provisionerd.py
          cp ${./test_provisionerd_ports.py} test_provisionerd_ports.py
          python3 -m unittest test_provisionerd_ports -v
          touch "$out"
        '';
    guestProfileTerminalCaTests =
      assert lib.hasInfix "TrustedUserCAKeys /var/lib/garnix/terminal-ca.pub"
        guestProfileConfig.services.openssh.extraConfig;
      assert lib.hasInfix
        "AuthorizedKeysFile %h/.ssh/authorized_keys /etc/ssh/authorized_keys.d/%u /var/garnix/keys/authorized_keys"
        guestProfileConfig.services.openssh.extraConfig;
      assert builtins.elem "d /var/lib/garnix 0755 root root - -"
        guestProfileConfig.systemd.tmpfiles.rules;
      assert builtins.elem
        "C /var/lib/garnix/terminal-ca.pub 0644 root root - /etc/ssh/garnix-hosting-ca.pub"
        guestProfileConfig.systemd.tmpfiles.rules;
      pkgs.runCommand "guest-profile-terminal-ca-tests" { } ''
        touch "$out"
      '';
    guestProfileStatsTests =
      assert builtins.hasAttr "garnix-stats-reporter" guestProfileConfig.systemd.services;
      assert builtins.hasAttr "garnix-stats-reporter" guestProfileConfig.systemd.timers;
      assert !(builtins.hasAttr "statsReportUrl" guestProfileConfig.garnix.guest);
      assert !(builtins.hasAttr "provisionerId" guestProfileConfig.garnix.guest);
      assert
        guestProfileConfig.systemd.timers.garnix-stats-reporter.unitConfig.ConditionPathExists
        == "/var/lib/garnix/stats.env";
      assert
        guestProfileConfig.systemd.services.garnix-stats-reporter.unitConfig.ConditionPathExists
        == "/var/lib/garnix/stats.env";
      assert
        guestProfileConfig.systemd.services.garnix-stats-reporter.serviceConfig.EnvironmentFile
        == "/var/lib/garnix/stats.env";
      assert !(builtins.hasAttr "garnix/stats.env" guestProfileConfig.environment.etc);
      assert
        !(builtins.elem "C /var/lib/garnix/stats.env 0644 root root - /etc/garnix/stats.env" guestProfileConfig.systemd.tmpfiles.rules);
      pkgs.runCommand "guest-profile-stats-tests"
        {
          nativeBuildInputs = [
            pkgs.coreutils
            pkgs.curl
            pkgs.gawk
            pkgs.python3
          ];
        }
        ''
          set -eu
          reporter=${guestProfileConfig.systemd.services.garnix-stats-reporter.serviceConfig.ExecStart}

          run_http_case() {
            response_status=$1
            expected_exit=$2
            expected_attempts=$3
            port=$4
            count_file=$TMPDIR/count-$response_status
            ready_file=$TMPDIR/ready-$response_status
            python3 ${statsHttpStub} "$response_status" "$port" "$count_file" "$ready_file" &
            server_pid=$!
            while [ ! -e "$ready_file" ]; do sleep 0.01; done
            if GARNIX_STATS_URL="http://127.0.0.1:$port/api/hosts/stats" \
              GARNIX_PROVISIONER_ID=42 \
              GARNIX_STATS_CPU_SAMPLE_DELAY=0 \
              GARNIX_STATS_RETRY_DELAY=0 \
              NO_PROXY=127.0.0.1 \
              "$reporter" >"$TMPDIR/stdout-$response_status" 2>"$TMPDIR/stderr-$response_status"; then
              actual_exit=0
            else
              actual_exit=$?
            fi
            kill "$server_pid"
            wait "$server_pid" 2>/dev/null || true
            test "$actual_exit" -eq "$expected_exit"
            test "$(cat "$count_file")" -eq "$expected_attempts"
          }

          run_http_case 204 0 1 18180
          run_http_case 302 1 3 18181
          run_http_case 404 1 3 18182
          run_http_case 503 1 3 18183

          if GARNIX_STATS_URL=http://127.0.0.1:18184/api/hosts/stats \
            GARNIX_PROVISIONER_ID=42 \
            GARNIX_STATS_CPU_SAMPLE_DELAY=0 \
            GARNIX_STATS_RETRY_DELAY=0 \
            NO_PROXY=127.0.0.1 \
            "$reporter" >"$TMPDIR/stdout-connection" 2>"$TMPDIR/stderr-connection"; then
            echo "connection failure unexpectedly succeeded" >&2
            exit 1
          fi
          test "$(grep -c '^curl:' "$TMPDIR/stderr-connection")" -eq 3
          grep -F 'failed after 3 attempts' "$TMPDIR/stderr-connection"
          touch "$out"
        '';
  };
}
