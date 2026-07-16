#!/usr/bin/env python3
"""Provision an Authentik OIDC app for a garnix-hosted deployment and print the
ready-to-paste `garnix.authentik` config block.

It drives the Authentik REST API (/api/v3) on your self-hosted instance and
age-encrypts the client secret to the repo's public key, so nothing secret ever
lands in the nix store. Two modes mirror the garnix-authentik module:

  dedicated  (default) — create a fresh OAuth2/OpenID provider + application, so
             the app appears on its own in Authentik and access is governed by
             that application's entitlements. Emits a new clientId + client
             secret. This is the "ideal" setup.

  shared     — reuse an existing provider/application (same clientId/secret/
             issuer) across many deployments. Instead of a new provider it adds
             one per-app *scope mapping* to the shared provider and gates this
             deployment on that scope's claim. Cheap to add apps; no new secret.

Auth: pass an Authentik API token (Directory → Tokens, or a service account) via
--token or the AUTHENTIK_TOKEN env var, and the instance URL via --authentik-url
or AUTHENTIK_URL.

Examples:

  # dedicated app, gated by group membership, secret encrypted to the repo key
  authentik-provision \\
    --authentik-url https://authentik.example.com --token "$AUTHENTIK_TOKEN" \\
    --name hello-locked \\
    --public-url https://hello-locked.main.myrepo.myorg.apps.example.com \\
    --repo-pubkey-url https://garnix.example.com/api/keys/myorg/myrepo/repo-key.public \\
    --group hello-locked-users

  # shared: add a scope mapping to an existing provider named "garnix-shared"
  authentik-provision --mode shared --provider garnix-shared \\
    --authentik-url https://authentik.example.com --token "$AUTHENTIK_TOKEN" \\
    --name reports \\
    --public-url https://reports.main.myrepo.myorg.apps.example.com \\
    --repo-pubkey-url https://garnix.example.com/api/keys/myorg/myrepo/repo-key.public \\
    --group reports-users
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


def die(msg):
    print(f"authentik-provision: error: {msg}", file=sys.stderr)
    sys.exit(1)


class Authentik:
    def __init__(self, base_url, token):
        self.base = base_url.rstrip("/")
        self.token = token
        # Property-mapping endpoints were namespaced under provider/ in newer
        # Authentik (2024.2+). Resolve which one this instance uses once.
        self._scope_pm_path = None

    def _req(self, method, path, body=None, query=None):
        url = f"{self.base}/api/v3{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            raise RuntimeError(f"{method} {path} -> HTTP {e.code}: {detail}") from None
        except urllib.error.URLError as e:
            die(f"cannot reach Authentik at {self.base}: {e.reason}")

    def get(self, path, query=None):
        return self._req("GET", path, query=query)

    def post(self, path, body):
        return self._req("POST", path, body=body)

    def patch(self, path, body):
        return self._req("PATCH", path, body=body)

    # --- resolution helpers ------------------------------------------------
    def scope_pm_path(self):
        if self._scope_pm_path is None:
            for candidate in ("/propertymappings/provider/scope/",
                              "/propertymappings/scope/"):
                try:
                    self.get(candidate, {"page_size": 1})
                    self._scope_pm_path = candidate
                    break
                except RuntimeError:
                    continue
            if self._scope_pm_path is None:
                die("could not locate the scope property-mapping API endpoint "
                    "(tried /propertymappings/provider/scope/ and "
                    "/propertymappings/scope/); check the Authentik version/token")
        return self._scope_pm_path

    def default_flow(self, designation, required):
        res = self.get("/flows/instances/", {"designation": designation})
        results = res.get("results", [])
        if not results:
            if required:
                die(f"no {designation} flow found in Authentik; create one first")
            return None
        # Prefer a flow whose slug hints at "default".
        for f in results:
            if "default" in f.get("slug", ""):
                return f["pk"]
        return results[0]["pk"]

    def signing_key(self):
        res = self.get("/crypto/certificatekeypairs/", {"has_key": "true"})
        results = res.get("results", [])
        if not results:
            die("no certificate-keypair with a private key found for token signing")
        for c in results:
            if "authentik" in c.get("name", "").lower():
                return c["pk"]
        return results[0]["pk"]

    def default_scope_mapping_pks(self):
        # The managed openid/email/profile scope mappings shipped with Authentik.
        res = self.get(self.scope_pm_path(), {"page_size": 100})
        wanted = {"openid", "email", "profile"}
        pks = [m["pk"] for m in res.get("results", [])
               if m.get("scope_name") in wanted]
        return pks

    def find_scope_mapping(self, scope_name):
        res = self.get(self.scope_pm_path(), {"scope_name": scope_name})
        for m in res.get("results", []):
            if m.get("scope_name") == scope_name:
                return m
        return None

    def ensure_scope_mapping(self, name, scope_name, claim):
        existing = self.find_scope_mapping(scope_name)
        expression = (
            "# garnix-authentik: surface the user's group names under the\n"
            f"# '{claim}' claim so the deployment's allowedGroups gate can check it.\n"
            f'return {{"{claim}": [group.name for group in '
            "request.user.ak_groups.all()]}"
        )
        if existing:
            return existing["pk"], False
        created = self.post(self.scope_pm_path(), {
            "name": name,
            "scope_name": scope_name,
            "expression": expression,
        })
        return created["pk"], True

    def find_provider(self, ref):
        # ref may be a numeric pk or a provider name.
        if str(ref).isdigit():
            return self.get(f"/providers/oauth2/{ref}/")
        res = self.get("/providers/oauth2/", {"search": ref})
        for p in res.get("results", []):
            if p.get("name") == ref:
                return self.get(f"/providers/oauth2/{p['pk']}/")
        die(f"no OAuth2 provider matching '{ref}' (use its exact name or pk)")

    def ensure_group(self, name):
        res = self.get("/core/groups/", {"name": name})
        for g in res.get("results", []):
            if g.get("name") == name:
                return g
        return self.post("/core/groups/", {"name": name})


def encrypt_secret(plaintext, recipients_file):
    try:
        out = subprocess.run(
            ["age", "--armor", "--recipients-file", recipients_file],
            input=plaintext.encode(), capture_output=True, check=True)
    except FileNotFoundError:
        die("`age` not found on PATH (needed to encrypt the client secret)")
    except subprocess.CalledProcessError as e:
        die(f"age encryption failed: {e.stderr.decode(errors='replace')}")
    return out.stdout.decode()


def fetch_repo_pubkey(url, out_path):
    try:
        with urllib.request.urlopen(url) as resp:
            data = resp.read()
    except (urllib.error.HTTPError, urllib.error.URLError) as e:
        die(f"could not fetch repo public key from {url}: {e}")
    with open(out_path, "wb") as f:
        f.write(data)
    return out_path


def redirect_uri_entry(url, matching_mode):
    return {"matching_mode": matching_mode, "url": url}


def indent(block, spaces):
    pad = " " * spaces
    return "\n".join(pad + line if line else line for line in block.splitlines())


def emit_config(mode, public_url, issuer_url, client_id, secret_age,
                scope, claim, group, upstream):
    ciphertext = indent(secret_age.strip(), 8)
    lines = [
        "garnix.authentik = {",
        "  enable = true;",
        f'  mode = "{mode}";',
        f'  publicUrl = "{public_url}";',
        f'  issuerUrl = "{issuer_url}";',
        f'  clientId = "{client_id}";',
        "  clientSecretAge = ''",
        ciphertext,
        "  '';",
    ]
    if mode == "shared" or scope != "openid profile email":
        lines.append(f'  scope = "{scope}";')
    if group:
        lines.append(f'  groupsClaim = "{claim}";')
        lines.append(f'  allowedGroups = [ "{group}" ];')
    lines.append(f'  upstream = "{upstream}";')
    lines.append("};")
    return "\n".join(lines)


def main():
    p = argparse.ArgumentParser(
        prog="authentik-provision",
        description="Provision an Authentik OIDC app for a garnix deployment.",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--authentik-url", default=os.environ.get("AUTHENTIK_URL"),
                   help="Authentik base URL (or AUTHENTIK_URL)")
    p.add_argument("--token", default=os.environ.get("AUTHENTIK_TOKEN"),
                   help="Authentik API token (or AUTHENTIK_TOKEN)")
    p.add_argument("--token-file",
                   help="read the API token from this file instead (e.g. an "
                        "agenix path like /run/agenix/authentik-api-token)")
    p.add_argument("--mode", choices=["dedicated", "shared"], default="dedicated")
    p.add_argument("--name", required=True,
                   help="app name / slug base (e.g. hello-locked)")
    p.add_argument("--public-url", required=True,
                   help="the deployment's external https URL (garnix app URL)")
    p.add_argument("--upstream", default="127.0.0.1:8080",
                   help="host:port your service listens on behind the gate")
    p.add_argument("--group", default=None,
                   help="Authentik group to gate on (created if missing). "
                        "Required in shared mode; optional in dedicated mode "
                        "(where entitlements can gate instead).")
    p.add_argument("--claim", default="groups",
                   help="token claim the scope mapping emits (default: groups)")
    p.add_argument("--scope-name", default=None,
                   help="custom OIDC scope name (default: <name>-entitlements)")
    p.add_argument("--provider", default=None,
                   help="shared mode: name or pk of the existing provider to extend")
    p.add_argument("--redirect-mode", choices=["strict", "regex"], default=None,
                   help="redirect URI matching mode. Default: strict (dedicated), "
                        "regex (shared, so one provider covers every app host).")
    grp = p.add_mutually_exclusive_group()
    grp.add_argument("--repo-pubkey-url",
                     help="URL of the repo public key "
                          "(GET /api/keys/<owner>/<repo>/repo-key.public)")
    grp.add_argument("--repo-pubkey-file",
                     help="path to the repo public key (age recipients file)")
    p.add_argument("--print-expression", action="store_true",
                   help="also print the scope-mapping expression for manual setup")
    args = p.parse_args()

    if not args.token and args.token_file:
        try:
            with open(args.token_file) as f:
                args.token = f.read().strip()
        except OSError as e:
            die(f"cannot read --token-file {args.token_file}: {e}")
    if not args.authentik_url:
        die("--authentik-url (or AUTHENTIK_URL) is required")
    if not args.token:
        die("--token / --token-file (or AUTHENTIK_TOKEN) is required")
    if args.mode == "shared":
        if not args.provider:
            die("--provider is required in shared mode "
                "(the existing provider to extend)")
        if not args.group:
            die("--group is required in shared mode "
                "(the scope-claim gate is the only per-app control)")

    scope_name = args.scope_name or f"{args.name}-entitlements"
    slug = args.name.lower().replace(" ", "-")
    ak = Authentik(args.authentik_url, args.token)

    # Where to encrypt the client secret to.
    pubkey_file = None
    if args.repo_pubkey_file:
        pubkey_file = args.repo_pubkey_file
    elif args.repo_pubkey_url:
        pubkey_file = fetch_repo_pubkey(args.repo_pubkey_url, f"/tmp/{slug}-repo.pub")

    # Per-app scope mapping (both modes: it carries the gating claim).
    mapping_pk = None
    if args.group:
        mapping_pk, created = ak.ensure_scope_mapping(
            name=f"garnix:{slug}:{args.claim}", scope_name=scope_name,
            claim=args.claim)
        print(f"→ scope mapping '{scope_name}' "
              f"({'created' if created else 'exists'}) emitting claim "
              f"'{args.claim}'", file=sys.stderr)
        ak.ensure_group(args.group)
        print(f"→ group '{args.group}' ensured", file=sys.stderr)

    if args.mode == "dedicated":
        redirect_mode = args.redirect_mode or "strict"
        auth_flow = ak.default_flow("authorization", required=True)
        inval_flow = ak.default_flow("invalidation", required=False) or auth_flow
        signing = ak.signing_key()
        pms = ak.default_scope_mapping_pks()
        if mapping_pk:
            pms.append(mapping_pk)
        provider = ak.post("/providers/oauth2/", {
            "name": args.name,
            "authorization_flow": auth_flow,
            "invalidation_flow": inval_flow,
            "client_type": "confidential",
            "redirect_uris": [redirect_uri_entry(
                f"{args.public_url}/oauth2/callback", redirect_mode)],
            "signing_key": signing,
            "property_mappings": pms,
            "sub_mode": "hashed_user_id",
        })
        pk = provider["pk"]
        full = ak.get(f"/providers/oauth2/{pk}/")
        client_id = full["client_id"]
        client_secret = full["client_secret"]
        ak.post("/core/applications/", {
            "name": args.name, "slug": slug, "provider": pk,
        })
        print(f"→ created provider + application '{slug}' (pk {pk})",
              file=sys.stderr)
        issuer = f"{ak.base}/application/o/{slug}/"
    else:  # shared
        provider = ak.find_provider(args.provider)
        pk = provider["pk"]
        client_id = provider["client_id"]
        client_secret = provider["client_secret"]
        # Add our scope mapping + this app's redirect URI to the shared provider.
        pms = list(provider.get("property_mappings", []))
        if mapping_pk and mapping_pk not in pms:
            pms.append(mapping_pk)
        redirect_mode = args.redirect_mode or "regex"
        redirects = list(provider.get("redirect_uris", []))
        new_uri = f"{args.public_url}/oauth2/callback"
        if redirect_mode == "regex":
            # A regex that covers every garnix app host under this domain, added
            # once; strict entries for individual apps still work alongside it.
            host = urllib.parse.urlparse(args.public_url).hostname or ""
            apex = ".".join(host.split(".")[-4:]) if host.count(".") >= 3 else host
            pattern = r"^https://[^/]+\." + apex.replace(".", r"\.") + r"/oauth2/callback$"
            if not any(r.get("url") == pattern for r in redirects):
                redirects.append(redirect_uri_entry(pattern, "regex"))
        else:
            if not any(r.get("url") == new_uri for r in redirects):
                redirects.append(redirect_uri_entry(new_uri, "strict"))
        ak.patch(f"/providers/oauth2/{pk}/", {
            "property_mappings": pms, "redirect_uris": redirects,
        })
        app_slug = provider.get("name", args.provider)
        # Issuer is the *shared* application's issuer. Try to find the app bound
        # to this provider; fall back to the provider name as the slug.
        apps = ak.get("/core/applications/", {"page_size": 100}).get("results", [])
        shared_slug = next(
            (a["slug"] for a in apps
             if a.get("provider") == pk or a.get("provider_obj", {}).get("pk") == pk),
            app_slug)
        issuer = f"{ak.base}/application/o/{shared_slug}/"
        print(f"→ extended shared provider '{args.provider}' with scope "
              f"'{scope_name}' + redirect ({redirect_mode})", file=sys.stderr)

    secret_age = encrypt_secret(client_secret, pubkey_file) if pubkey_file else None

    scope = "openid profile email"
    if args.group:
        scope = f"openid profile email {scope_name}"

    print(file=sys.stderr)
    if secret_age is None:
        print("!! no --repo-pubkey-url/--repo-pubkey-file given; the clientSecret "
              "below is PLAINTEXT — encrypt it with `age -R <repo.pub> -a` before "
              "committing.", file=sys.stderr)
        secret_block = client_secret
    else:
        secret_block = secret_age

    if args.print_expression:
        print("# scope mapping expression:", file=sys.stderr)
        print(f'#   return {{"{args.claim}": [group.name for group in '
              "request.user.ak_groups.all()]}", file=sys.stderr)

    # The pasteable config block on stdout.
    if secret_age is None:
        # Emit with a placeholder rather than a bare plaintext age field.
        cfg = emit_config(args.mode, args.public_url, issuer, client_id,
                          "-----BEGIN AGE ENCRYPTED FILE-----\n"
                          f"<age -R repo.pub -a of: {secret_block}>\n"
                          "-----END AGE ENCRYPTED FILE-----",
                          scope, args.claim, args.group, args.upstream)
    else:
        cfg = emit_config(args.mode, args.public_url, issuer, client_id,
                          secret_age, scope, args.claim, args.group, args.upstream)
    print(cfg)


if __name__ == "__main__":
    main()
