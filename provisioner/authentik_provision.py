#!/usr/bin/env python3
"""Provision an Authentik OIDC app for a garnix-hosted deployment and print the
ready-to-paste `garnix.authentik` config block.

It drives the Authentik REST API (/api/v3) on your self-hosted instance and
writes the client secret to a committed `.age` file (encrypted to the repo's
public key), so nothing secret lands in the nix store. Two modes mirror the
garnix-authentik module:

  dedicated  (default) — create a fresh OAuth2/OpenID provider + application, so
             the app appears on its own in Authentik. Emits a new clientId +
             client secret. This is the "ideal" setup.

  shared     — reuse an existing provider/application (same clientId/secret/
             issuer) across many deployments. Instead of a new provider it adds
             one per-app *scope mapping* to the shared provider. No new secret.

Access control (both modes) follows the Authentik **application entitlements**
pattern: the helper creates the named entitlements on the application and a
scope mapping whose expression reads
`request.user.app_entitlements(provider.application)` and maps each entitlement
name to a group name emitted under `--claim` (default `groups`), e.g.

  entitlement_names = {
      e.name for e in request.user.app_entitlements(provider.application)
  }
  groups = []
  if "reports-user" in entitlement_names:
      groups.append("reports-users")
  return {"groups": groups}

You bind users/groups to those entitlements in Authentik; oauth2-proxy on the
guest gates on the emitted group via garnix.authentik.allowedGroups.

Auth: pass an Authentik API token (Directory → Tokens, or a service account) via
--token, --token-file, or the AUTHENTIK_TOKEN env var, and the instance URL via
--authentik-url or AUTHENTIK_URL.

Defaults keep the common case short: the token comes from the agenix path
/run/agenix/authentik-api-token, and --entitlement defaults to
<name>-user=<name>-users.

Examples:

  # dedicated: token + entitlement both defaulted. Creates provider + app +
  # the "hello-locked-user" entitlement -> "hello-locked-users" group.
  authentik-provision \\
    --authentik-url https://authentik.example.com \\
    --name hello-locked \\
    --public-url https://hello-locked.main.myrepo.myorg.apps.example.com \\
    --repo-pubkey-url https://garnix.example.com/api/keys/myorg/myrepo/repo-key.public

  # shared: reuse "garnix-shared"; extra role + explicit token override shown
  authentik-provision --mode shared --provider garnix-shared \\
    --authentik-url https://authentik.example.com \\
    --token-file /run/agenix/authentik-api-token \\
    --name reports \\
    --entitlement reports-user=reports-users \\
    --entitlement reports-admin=reports-admins \\
    --public-url https://reports.main.myrepo.myorg.apps.example.com \\
    --repo-pubkey-url https://garnix.example.com/api/keys/myorg/myrepo/repo-key.public
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


# Default agenix path for the Authentik API token on garnix workstations, so the
# common case needs no --token/--token-file. --token / AUTHENTIK_TOKEN override.
DEFAULT_TOKEN_FILE = "/run/agenix/authentik-api-token"


def resolve_token(token, token_file):
    """Resolve the API token: an explicit --token / AUTHENTIK_TOKEN wins, else
    read token_file. A missing *default* token file returns None (the caller
    then errors); a missing *explicitly-set* --token-file is a hard error."""
    if token:
        return token
    if token_file:
        try:
            with open(token_file) as f:
                return f.read().strip() or None
        except OSError as e:
            if token_file != DEFAULT_TOKEN_FILE:
                die(f"cannot read --token-file {token_file}: {e}")
            return None
    return None


def parse_entitlement_pairs(specs, slug):
    """Turn --entitlement SPECs into (entitlement_name, group_name) pairs.

    A SPEC is either ``ENT`` (group defaults to ENT) or ``ENT=GROUP``. With no
    specs, default to a single ``<slug>-user`` -> ``<slug>-users`` pair.
    """
    if not specs:
        return [(f"{slug}-user", f"{slug}-users")]
    pairs = []
    for spec in specs:
        ent, sep, group = spec.partition("=")
        ent = ent.strip()
        group = group.strip() if sep else ent
        if not ent or not group:
            die(f"invalid --entitlement {spec!r} (expected ENT or ENT=GROUP)")
        pairs.append((ent, group))
    return pairs


def scope_mapping_expression(pairs, claim):
    """Build the Authentik scope-mapping expression that maps this app's
    entitlements to group names under `claim` (the pattern from the garnix
    "garnix groups" mapping, generalized per app)."""
    lines = [
        "entitlement_names = {",
        "    e.name for e in request.user.app_entitlements(provider.application)",
        "}",
        "groups = []",
    ]
    for ent, group in pairs:
        lines.append(f'if "{ent}" in entitlement_names:')
        lines.append(f'    groups.append("{group}")')
    lines.append(f'return {{"{claim}": groups}}')
    return "\n".join(lines)


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
        return [m["pk"] for m in res.get("results", [])
                if m.get("scope_name") in wanted]

    def find_scope_mapping(self, scope_name):
        res = self.get(self.scope_pm_path(), {"scope_name": scope_name})
        for m in res.get("results", []):
            if m.get("scope_name") == scope_name:
                return m
        return None

    def ensure_scope_mapping(self, name, scope_name, expression):
        """Create the scope mapping if absent; if present, update its expression
        so re-running the helper keeps the entitlement->group logic current."""
        existing = self.find_scope_mapping(scope_name)
        if existing:
            self.patch(f"{self.scope_pm_path()}{existing['pk']}/",
                       {"name": name, "expression": expression})
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

    def find_application_for_provider(self, provider_pk):
        apps = self.get("/core/applications/", {"page_size": 100}).get("results", [])
        for a in apps:
            if a.get("provider") == provider_pk:
                return a
        return None

    def ensure_entitlement(self, app_pk, name):
        """Ensure an application entitlement `name` exists on the application.

        Returns (obj_or_None, warning_or_None). Application entitlements are a
        preview API (Authentik 2024.8+); if it's missing we warn rather than die
        so the rest of the provisioning still succeeds.
        """
        try:
            res = self.get("/core/application_entitlements/", {"app": app_pk})
        except RuntimeError as e:
            return None, f"entitlements API unavailable ({e}); create '{name}' by hand"
        for ent in res.get("results", []):
            if ent.get("name") == name:
                return ent, None
        try:
            created = self.post("/core/application_entitlements/",
                                {"name": name, "app": app_pk})
            return created, None
        except RuntimeError as e:
            return None, f"could not create entitlement '{name}': {e}"


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


def app_host_regex(public_url):
    """A redirect-URI regex that covers every garnix app host under the same
    apps domain, so one shared provider needn't be edited per app."""
    host = urllib.parse.urlparse(public_url).hostname or ""
    apex = ".".join(host.split(".")[-4:]) if host.count(".") >= 3 else host
    return r"^https://[^/]+\." + apex.replace(".", r"\.") + r"/oauth2/callback$"


def nix_path_literal(path):
    if path.startswith(("/", "./", "../")):
        return path
    return "./" + path


def nix_str_list(values):
    return "[ " + " ".join(f'"{v}"' for v in values) + " ]"


def emit_config(mode, public_url, issuer_url, client_id, secret_file_ref,
                scope, claim, groups, upstream):
    lines = [
        "garnix.authentik = {",
        "  enable = true;",
        f'  mode = "{mode}";',
        f'  publicUrl = "{public_url}";',
        f'  issuerUrl = "{issuer_url}";',
        f'  clientId = "{client_id}";',
        f"  clientSecretFile = {secret_file_ref};",
    ]
    if mode == "shared" or scope != "openid profile email":
        lines.append(f'  scope = "{scope}";')
    if groups:
        lines.append(f'  groupsClaim = "{claim}";')
        lines.append(f"  allowedGroups = {nix_str_list(groups)};")
    lines.append(f'  upstream = "{upstream}";')
    lines.append("};")
    return "\n".join(lines)


def build_parser():
    p = argparse.ArgumentParser(
        prog="authentik-provision",
        description="Provision an Authentik OIDC app for a garnix deployment.",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--authentik-url", default=os.environ.get("AUTHENTIK_URL"),
                   help="Authentik base URL (or AUTHENTIK_URL)")
    p.add_argument("--token", default=os.environ.get("AUTHENTIK_TOKEN"),
                   help="Authentik API token (or AUTHENTIK_TOKEN)")
    p.add_argument("--token-file", default=DEFAULT_TOKEN_FILE,
                   help=f"read the API token from this file (default: "
                        f"{DEFAULT_TOKEN_FILE}, the agenix path); --token / "
                        "AUTHENTIK_TOKEN take precedence")
    p.add_argument("--mode", choices=["dedicated", "shared"], default="dedicated")
    p.add_argument("--name", required=True,
                   help="app name / slug base (e.g. hello-locked)")
    p.add_argument("--public-url", required=True,
                   help="the deployment's external https URL (garnix app URL)")
    p.add_argument("--upstream", default="127.0.0.1:8080",
                   help="host:port your service listens on behind the gate")
    p.add_argument("--entitlement", action="append", default=[], metavar="ENT[=GROUP]",
                   help="application entitlement to create + gate on, mapped to a "
                        "group name in the claim (repeatable). Default: "
                        "<name>-user=<name>-users.")
    p.add_argument("--claim", default="groups",
                   help="token claim the scope mapping emits (default: groups)")
    p.add_argument("--scope-name", default=None,
                   help="custom OIDC scope name (default: the app slug)")
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
    p.add_argument("--secret-file", default=None,
                   help="write the age-encrypted client secret to this path and "
                        "reference it as clientSecretFile "
                        "(default: <name>-client-secret.age)")
    p.add_argument("--print-expression", action="store_true",
                   help="also print the generated scope-mapping expression")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)

    args.token = resolve_token(args.token, args.token_file)
    if not args.authentik_url:
        die("--authentik-url (or AUTHENTIK_URL) is required")
    if not args.token:
        die(f"no API token: pass --token, set AUTHENTIK_TOKEN, or make the token "
            f"file readable (--token-file, default {DEFAULT_TOKEN_FILE})")
    if args.mode == "shared" and not args.provider:
        die("--provider is required in shared mode (the existing provider to extend)")

    slug = args.name.lower().replace(" ", "-")
    scope_name = args.scope_name or slug
    pairs = parse_entitlement_pairs(args.entitlement, slug)
    claim = args.claim
    groups = [group for _ent, group in pairs]
    expression = scope_mapping_expression(pairs, claim)
    ak = Authentik(args.authentik_url, args.token)

    # Where to encrypt the client secret to.
    pubkey_file = None
    if args.repo_pubkey_file:
        pubkey_file = args.repo_pubkey_file
    elif args.repo_pubkey_url:
        pubkey_file = fetch_repo_pubkey(args.repo_pubkey_url, f"/tmp/{slug}-repo.pub")

    # The per-app scope mapping (its expression references provider.application,
    # resolved at token time, so it needs no app pk to create).
    mapping_pk, created = ak.ensure_scope_mapping(
        name=f"garnix:{slug}:{claim}", scope_name=scope_name, expression=expression)
    print(f"→ scope mapping '{scope_name}' "
          f"({'created' if created else 'updated'}) emitting claim '{claim}'",
          file=sys.stderr)

    if args.mode == "dedicated":
        redirect_mode = args.redirect_mode or "strict"
        auth_flow = ak.default_flow("authorization", required=True)
        inval_flow = ak.default_flow("invalidation", required=False) or auth_flow
        signing = ak.signing_key()
        pms = ak.default_scope_mapping_pks()
        if mapping_pk not in pms:
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
        app = ak.post("/core/applications/", {
            "name": args.name, "slug": slug, "provider": pk,
        })
        app_pk = app["pk"]
        print(f"→ created provider + application '{slug}' (pk {pk})", file=sys.stderr)
        issuer = f"{ak.base}/application/o/{slug}/"
    else:  # shared
        provider = ak.find_provider(args.provider)
        pk = provider["pk"]
        client_id = provider["client_id"]
        client_secret = provider["client_secret"]
        # Add our scope mapping + this app's redirect URI to the shared provider.
        pms = list(provider.get("property_mappings", []))
        if mapping_pk not in pms:
            pms.append(mapping_pk)
        redirect_mode = args.redirect_mode or "strict"
        redirects = list(provider.get("redirect_uris", []))
        if redirect_mode == "regex":
            pattern = app_host_regex(args.public_url)
            if not any(r.get("url") == pattern for r in redirects):
                redirects.append(redirect_uri_entry(pattern, "regex"))
        else:
            new_uri = f"{args.public_url}/oauth2/callback"
            if not any(r.get("url") == new_uri for r in redirects):
                redirects.append(redirect_uri_entry(new_uri, "strict"))
        ak.patch(f"/providers/oauth2/{pk}/", {
            "property_mappings": pms, "redirect_uris": redirects,
        })
        shared_app = ak.find_application_for_provider(pk)
        app_pk = shared_app["pk"] if shared_app else None
        shared_slug = shared_app["slug"] if shared_app else provider.get("name", args.provider)
        issuer = f"{ak.base}/application/o/{shared_slug}/"
        print(f"→ extended shared provider '{args.provider}' with scope "
              f"'{scope_name}' + redirect ({redirect_mode})", file=sys.stderr)

    # Create the application entitlements the scope mapping keys off.
    if app_pk is None:
        print("!! could not resolve the application for entitlement creation; "
              f"create these entitlements by hand: {', '.join(e for e, _ in pairs)}",
              file=sys.stderr)
    else:
        for ent, _group in pairs:
            _obj, warn = ak.ensure_entitlement(app_pk, ent)
            if warn:
                print(f"!! {warn}", file=sys.stderr)
            else:
                print(f"→ entitlement '{ent}' ensured on the application",
                      file=sys.stderr)

    secret_file = args.secret_file or f"{slug}-client-secret.age"
    scope = f"openid profile email {scope_name}"

    print(file=sys.stderr)
    if pubkey_file:
        secret_age = encrypt_secret(client_secret, pubkey_file)
        with open(secret_file, "w") as f:
            f.write(secret_age if secret_age.endswith("\n") else secret_age + "\n")
        print(f"→ wrote encrypted client secret to {secret_file} — commit it; "
              "it is referenced below by clientSecretFile", file=sys.stderr)
    else:
        print("!! no --repo-pubkey-url/--repo-pubkey-file given; NOT writing the "
              f"secret file. Encrypt the client secret yourself into {secret_file}:\n"
              f"     printf %s '{client_secret}' | age -R repo.pub -a > {secret_file}",
              file=sys.stderr)

    print("→ bind users/groups to the entitlements "
          f"({', '.join(e for e, _ in pairs)}) in Authentik to grant access",
          file=sys.stderr)
    if args.print_expression:
        print("\n# scope mapping expression:", file=sys.stderr)
        for line in expression.splitlines():
            print(f"#   {line}", file=sys.stderr)

    # The pasteable config block on stdout — always references the .age file by
    # path (never inline ciphertext).
    cfg = emit_config(args.mode, args.public_url, issuer, client_id,
                      nix_path_literal(secret_file), scope, claim, groups,
                      args.upstream)
    print(cfg)


if __name__ == "__main__":
    main()
