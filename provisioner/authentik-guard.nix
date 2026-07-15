# garnix-authentik: lock a garnix-deployed server behind Authentik (or any
# OIDC provider) with one import.
#
# Import this into a deployed nixosConfiguration (alongside
# microvm.nixosModules.microvm + garnix-ci.nixosModules.garnix-guest) and point
# `garnix.authentik.upstream` at your own service. The module runs oauth2-proxy
# (OIDC) plus an nginx forward-auth gate on port 80 (the port Traefik proxies
# to), so every request must carry a valid Authentik session before it reaches
# your service.
#
# Secrets: the OIDC client secret is supplied as an *age ciphertext* encrypted
# to the repo's public key (GET /api/keys/<owner>/<repo>/repo-key.public). It is
# safe to commit — it is decrypted at runtime on the guest with the repo private
# key garnix drops at /var/garnix/keys/repo-key (root-only, 0400). No plaintext
# secret ever lands in the world-readable nix store. The cookie secret is
# generated once on the guest and persisted.
#
# Example (in your deployed config):
#
#   garnix.authentik = {
#     enable = true;
#     publicUrl = "https://app.main.myrepo.myorg.apps.example.com";
#     issuerUrl = "https://authentik.example.com/application/o/myapp/";
#     clientId = "abc123";
#     allowedGroups = [ "my-app-users" ];   # omit to allow any authenticated user
#     upstream = "127.0.0.1:8080";          # your service (must NOT listen on :80)
#     clientSecretAge = ''
#       -----BEGIN AGE ENCRYPTED FILE-----
#       ...
#       -----END AGE ENCRYPTED FILE-----
#     '';
#   };
#   services.myThing.port = 8080;           # your actual app, behind the gate
{ lib, config, pkgs, ... }:
let
  cfg = config.garnix.authentik;
  runDir = "/run/garnix-authentik";
  stateDir = "/var/lib/garnix-authentik";
  envFile = "${runDir}/oauth2.env";
  # The repo age key garnix delivers to every provisioned guest; it can decrypt
  # anything encrypted to that repo's public key.
  repoKey = "/var/garnix/keys/repo-key";
in
{
  options.garnix.authentik = {
    enable = lib.mkEnableOption "Authentik/OIDC protection in front of the deployed service";

    publicUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://app.main.myrepo.myorg.apps.example.com";
      description = ''
        The full external https URL this server is reached at. Used for the OIDC
        redirect URL (<publicUrl>/oauth2/callback) and the post-login redirect
        whitelist. Must match the domain garnix routes to this server.
      '';
    };

    issuerUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://authentik.example.com/application/o/myapp/";
      description = "OIDC issuer URL (Authentik application's OIDC issuer).";
    };

    clientId = lib.mkOption {
      type = lib.types.str;
      description = "OIDC client ID for this application in Authentik.";
    };

    clientSecretAge = lib.mkOption {
      type = lib.types.str;
      description = ''
        The OIDC client secret, as an age ciphertext encrypted to this repo's
        public key (from GET /api/keys/<owner>/<repo>/repo-key.public). Safe to
        commit; decrypted at runtime with the repo key on the guest.
      '';
    };

    scope = lib.mkOption {
      type = lib.types.str;
      default = "openid profile email";
      example = "openid profile email myapp-entitlements";
      description = ''
        OIDC scopes to request. Add a custom Authentik scope here if you use a
        scope mapping to emit a per-app groups/entitlements claim (see the
        Authentik cookbook in docs/authentik-cookbook.md).
      '';
    };

    groupsClaim = lib.mkOption {
      type = lib.types.str;
      default = "groups";
      example = "entitlements";
      description = ''
        The token claim that `allowedGroups` is checked against. Point this at
        whatever claim your Authentik scope mapping emits (e.g. "groups",
        "entitlements", "roles"). Only used when `allowedGroups` is non-empty.
      '';
    };

    allowedGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "myapp-users" ];
      description = ''
        Restrict access to principals whose `groupsClaim` contains one of these
        values. Empty (default) allows any successfully-authenticated user (so
        access is governed purely by the Authentik application's entitlement
        bindings — who is allowed to log into the app at all).
      '';
    };

    upstream = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:8080";
      example = "127.0.0.1:8080";
      description = ''
        host:port of the service to protect. Your service must listen here (NOT
        on :80 — this module owns :80 for the auth gate).
      '';
    };

    emailDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "*" ];
      description = "Allowed email domains ([\"*\"] = any).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Prepare the oauth2-proxy env file (client + cookie secret) on the guest,
    # decrypting the client secret with the repo key. Runs as root because the
    # repo key is 0400 root; the key is delivered post-boot by garnix over SSH,
    # so wait for it.
    systemd.services.garnix-authentik-secrets = {
      description = "Decrypt garnix-authentik OIDC secrets";
      before = [ "oauth2-proxy.service" ];
      requiredBy = [ "oauth2-proxy.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "garnix-authentik";
        StateDirectory = "garnix-authentik";
      };
      path = [ pkgs.age pkgs.coreutils ];
      script = ''
        set -euo pipefail
        # The repo key is copied in by garnix shortly after boot; wait for it.
        for _ in $(seq 1 120); do
          [ -f ${repoKey} ] && break
          sleep 2
        done
        if [ ! -f ${repoKey} ]; then
          echo "garnix-authentik: ${repoKey} never appeared; cannot decrypt client secret" >&2
          exit 1
        fi
        client_secret="$(printf '%s' ${lib.escapeShellArg cfg.clientSecretAge} | age --decrypt -i ${repoKey})"
        # Cookie secret: generate once, persist across restarts within this guest.
        if [ ! -s ${stateDir}/cookie-secret ]; then
          head -c 32 /dev/urandom | base64 -w0 > ${stateDir}/cookie-secret
        fi
        umask 077
        {
          printf 'OAUTH2_PROXY_CLIENT_SECRET=%s\n' "$client_secret"
          printf 'OAUTH2_PROXY_COOKIE_SECRET=%s\n' "$(cat ${stateDir}/cookie-secret)"
        } > ${envFile}
        # oauth2-proxy's keyFile is read by systemd as an EnvironmentFile (as
        # root, before dropping privileges), so root-only 0600 is enough.
        chmod 600 ${envFile}
      '';
    };

    services.oauth2-proxy = {
      enable = true;
      provider = "oidc";
      clientID = cfg.clientId;
      oidcIssuerUrl = cfg.issuerUrl;
      redirectURL = "${cfg.publicUrl}/oauth2/callback";
      scope = cfg.scope;
      reverseProxy = true; # honour X-Forwarded-* from the fronting proxy (the local nginx gate)
      # Only the loopback nginx gate talks to oauth2-proxy, so only trust
      # forwarded headers from loopback — otherwise oauth2-proxy trusts all
      # source IPs and a client could spoof X-Forwarded-* / identity headers.
      trustedProxyIP = [ "127.0.0.1/32" "::1/128" ];
      setXauthrequest = true;
      httpAddress = "127.0.0.1:4180";
      email.domains = cfg.emailDomains;
      cookie.secure = true;
      # Secrets come from the env file the oneshot above writes.
      keyFile = envFile;
      extraConfig = {
        skip-provider-button = true;
        # Authentik commonly issues id_tokens with email_verified=false.
        insecure-oidc-allow-unverified-email = true;
        # Allow the post-login rd= redirect back to this host.
        whitelist-domain = [ (lib.removePrefix "https://" (lib.removePrefix "http://" cfg.publicUrl)) ];
      }
      // lib.optionalAttrs (cfg.allowedGroups != [ ]) {
        allowed-group = cfg.allowedGroups;
        oidc-groups-claim = cfg.groupsClaim;
      };
    };
    systemd.services.oauth2-proxy = {
      after = [ "garnix-authentik-secrets.service" ];
      wants = [ "garnix-authentik-secrets.service" ];
    };

    # nginx forward-auth gate on :80 (the port Traefik proxies to). Strips any
    # client-supplied auth headers, proxies /oauth2/* to the proxy, and gates
    # everything else through /oauth2/auth before reaching the upstream.
    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      virtualHosts."_" = {
        default = true;
        locations = {
          "/oauth2/" = {
            proxyPass = "http://127.0.0.1:4180";
            extraConfig = ''
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Scheme $scheme;
              proxy_set_header X-Auth-Request-Redirect $request_uri;
            '';
          };
          "= /oauth2/auth" = {
            proxyPass = "http://127.0.0.1:4180";
            extraConfig = ''
              internal;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Original-URI $request_uri;
              proxy_pass_request_body off;
              proxy_set_header Content-Length "";
            '';
          };
          "/" = {
            proxyPass = "http://${cfg.upstream}";
            extraConfig = ''
              # Never trust client-supplied identity headers.
              proxy_set_header X-Auth-Request-User "";
              proxy_set_header X-Auth-Request-Email "";
              proxy_set_header X-Auth-Request-Groups "";

              auth_request /oauth2/auth;
              error_page 401 = @oauth2_signin;

              auth_request_set $auth_user   $upstream_http_x_auth_request_user;
              auth_request_set $auth_email  $upstream_http_x_auth_request_email;
              auth_request_set $auth_groups $upstream_http_x_auth_request_groups;
              proxy_set_header X-Auth-Request-User   $auth_user;
              proxy_set_header X-Auth-Request-Email  $auth_email;
              proxy_set_header X-Auth-Request-Groups $auth_groups;
            '';
          };
          "@oauth2_signin" = {
            extraConfig = ''
              return 302 /oauth2/start?rd=$scheme://$host$request_uri;
            '';
          };
        };
      };
    };
  };
}
