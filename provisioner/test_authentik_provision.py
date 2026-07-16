#!/usr/bin/env python3
"""Unit tests for authentik_provision. No network: the Authentik REST client
(_req / get / post / patch) and age encryption are mocked, so these exercise the
pure helpers, the API-call shapes, and the dedicated/shared main() flows."""
import io
import os
import tempfile
import unittest
from unittest import mock

import authentik_provision as ap


class PureFnTests(unittest.TestCase):
    def test_parse_default(self):
        self.assertEqual(ap.parse_entitlement_pairs([], "reports"),
                         [("reports-user", "reports-users")])

    def test_parse_specs(self):
        self.assertEqual(
            ap.parse_entitlement_pairs(["garnixuser=garnix-users", "solo"], "x"),
            [("garnixuser", "garnix-users"), ("solo", "solo")])

    def test_parse_invalid(self):
        with self.assertRaises(SystemExit):
            ap.parse_entitlement_pairs(["=nope"], "x")

    def test_expression_matches_app_entitlements_pattern(self):
        expr = ap.scope_mapping_expression(
            [("garnixadmin", "garnix-admins"), ("garnixuser", "garnix-users")],
            "groups")
        self.assertIn(
            "request.user.app_entitlements(provider.application)", expr)
        self.assertIn('if "garnixadmin" in entitlement_names:', expr)
        self.assertIn('    groups.append("garnix-admins")', expr)
        self.assertIn('if "garnixuser" in entitlement_names:', expr)
        self.assertIn('    groups.append("garnix-users")', expr)
        self.assertTrue(expr.strip().endswith('return {"groups": groups}'))

    def test_expression_custom_claim(self):
        expr = ap.scope_mapping_expression([("e", "g")], "entitlements")
        self.assertIn('return {"entitlements": groups}', expr)

    def test_nix_path_literal(self):
        self.assertEqual(ap.nix_path_literal("x.age"), "./x.age")
        self.assertEqual(ap.nix_path_literal("./x.age"), "./x.age")
        self.assertEqual(ap.nix_path_literal("../x.age"), "../x.age")
        self.assertEqual(ap.nix_path_literal("/a/x.age"), "/a/x.age")

    def test_nix_str_list(self):
        self.assertEqual(ap.nix_str_list(["a", "b"]), '[ "a" "b" ]')
        self.assertEqual(ap.nix_str_list(["only"]), '[ "only" ]')

    def test_app_host_regex(self):
        rx = ap.app_host_regex(
            "https://reports.main.repo.owner.apps.example.com")
        self.assertTrue(rx.startswith(r"^https://[^/]+\."))
        self.assertTrue(rx.endswith(r"/oauth2/callback$"))

    def test_emit_config_shared_uses_file_and_list(self):
        cfg = ap.emit_config(
            "shared", "https://app", "https://iss", "cid", "./s.age",
            "openid profile email reports", "groups",
            ["reports-users", "reports-admins"], "127.0.0.1:8080")
        self.assertIn('mode = "shared";', cfg)
        self.assertIn("clientSecretFile = ./s.age;", cfg)
        self.assertIn('scope = "openid profile email reports";', cfg)
        self.assertIn('allowedGroups = [ "reports-users" "reports-admins" ];', cfg)
        self.assertNotIn("clientSecretAge", cfg)  # never inline ciphertext

    def test_emit_config_dedicated_default_scope_omitted(self):
        cfg = ap.emit_config(
            "dedicated", "https://app", "https://iss", "cid", "./s.age",
            "openid profile email", "groups", [], "127.0.0.1:8080")
        self.assertNotIn("scope =", cfg)
        self.assertNotIn("allowedGroups", cfg)


class AuthentikMethodTests(unittest.TestCase):
    def _ak(self):
        ak = ap.Authentik("https://ak.example.com", "T")
        ak._scope_pm_path = "/propertymappings/provider/scope/"
        return ak

    def test_ensure_scope_mapping_create(self):
        ak = self._ak()
        ak.get = mock.Mock(return_value={"results": []})
        ak.post = mock.Mock(return_value={"pk": "new"})
        ak.patch = mock.Mock()
        pk, created = ak.ensure_scope_mapping("n", "s", "EXPR")
        self.assertEqual((pk, created), ("new", True))
        ak.post.assert_called_once()
        self.assertEqual(ak.post.call_args.args[1]["expression"], "EXPR")
        ak.patch.assert_not_called()

    def test_ensure_scope_mapping_update(self):
        ak = self._ak()
        ak.get = mock.Mock(return_value={"results": [{"pk": "ex", "scope_name": "s"}]})
        ak.post = mock.Mock()
        ak.patch = mock.Mock()
        pk, created = ak.ensure_scope_mapping("n", "s", "EXPR2")
        self.assertEqual((pk, created), ("ex", False))
        ak.post.assert_not_called()
        ak.patch.assert_called_once_with(
            "/propertymappings/provider/scope/ex/",
            {"name": "n", "expression": "EXPR2"})

    def test_ensure_entitlement_create(self):
        ak = self._ak()
        ak.get = mock.Mock(return_value={"results": []})
        ak.post = mock.Mock(return_value={"pk": "e"})
        obj, warn = ak.ensure_entitlement("app-uuid", "reports-user")
        self.assertIsNone(warn)
        ak.post.assert_called_once_with(
            "/core/application_entitlements/",
            {"name": "reports-user", "app": "app-uuid"})

    def test_ensure_entitlement_exists(self):
        ak = self._ak()
        ak.get = mock.Mock(return_value={"results": [{"name": "reports-user"}]})
        ak.post = mock.Mock()
        obj, warn = ak.ensure_entitlement("app-uuid", "reports-user")
        self.assertIsNone(warn)
        ak.post.assert_not_called()

    def test_ensure_entitlement_api_unavailable(self):
        ak = self._ak()
        ak.get = mock.Mock(side_effect=RuntimeError("GET ... -> HTTP 404"))
        obj, warn = ak.ensure_entitlement("app-uuid", "reports-user")
        self.assertIsNone(obj)
        self.assertIn("reports-user", warn)

    def test_default_scope_mapping_pks_filters(self):
        ak = self._ak()
        ak.get = mock.Mock(return_value={"results": [
            {"pk": "o", "scope_name": "openid"},
            {"pk": "custom", "scope_name": "reports"},
            {"pk": "e", "scope_name": "email"},
            {"pk": "p", "scope_name": "profile"}]})
        self.assertEqual(set(ak.default_scope_mapping_pks()), {"o", "e", "p"})

    def test_find_application_for_provider(self):
        ak = self._ak()
        ak.get = mock.Mock(return_value={"results": [
            {"pk": "a1", "provider": 7}, {"pk": "a2", "provider": 8}]})
        self.assertEqual(ak.find_application_for_provider(7)["pk"], "a1")
        self.assertIsNone(ak.find_application_for_provider(99))


def _run_main(dispatch, argv):
    """Run main() with Authentik._req and encrypt_secret mocked, in a temp CWD.
    Returns (stdout, stderr, secret_file_written_bool)."""
    with tempfile.TemporaryDirectory() as d:
        pub = os.path.join(d, "repo.pub")
        with open(pub, "w") as f:
            f.write("age1fakerecipient\n")
        cwd = os.getcwd()
        os.chdir(d)
        try:
            with mock.patch.object(ap.Authentik, "_req", new=dispatch), \
                 mock.patch.object(ap, "encrypt_secret",
                                   return_value="-----BEGIN AGE ENCRYPTED FILE-----\n"
                                                "ciphertext\n-----END AGE ENCRYPTED FILE-----\n"), \
                 mock.patch("sys.stdout", new_callable=io.StringIO) as out, \
                 mock.patch("sys.stderr", new_callable=io.StringIO) as err:
                ap.main(argv + ["--repo-pubkey-file", pub])
            written = os.path.exists("reports-client-secret.age") or \
                os.path.exists("hello-locked-client-secret.age")
            return out.getvalue(), err.getvalue(), written
        finally:
            os.chdir(cwd)


class MainDedicatedTest(unittest.TestCase):
    def test_dedicated_flow(self):
        rec = []

        def dispatch(self, method, path, body=None, query=None):
            rec.append((method, path, body, query))
            if path == "/propertymappings/provider/scope/":
                if method == "POST":
                    return {"pk": "map-pk"}
                q = query or {}
                if q.get("page_size") == 1:
                    return {}
                if q.get("page_size") == 100:
                    return {"results": [
                        {"pk": "openid", "scope_name": "openid"},
                        {"pk": "email", "scope_name": "email"},
                        {"pk": "profile", "scope_name": "profile"}]}
                return {"results": []}
            if path == "/flows/instances/":
                d = (query or {}).get("designation")
                return {"results": [{"pk": f"{d}-flow", "slug": f"default-{d}-flow"}]}
            if path == "/crypto/certificatekeypairs/":
                return {"results": [{"pk": "cert", "name": "authentik Self-signed"}]}
            if path == "/providers/oauth2/" and method == "POST":
                return {"pk": 42}
            if path == "/providers/oauth2/42/":
                return {"client_id": "cid", "client_secret": "csecret"}
            if path == "/core/applications/" and method == "POST":
                return {"pk": "app-uuid", "slug": "hello-locked"}
            if path == "/core/application_entitlements/":
                return {"results": []} if method == "GET" else {"pk": "ent"}
            return {}

        out, err, written = _run_main(dispatch, [
            "--authentik-url", "https://ak.example.com", "--token", "T",
            "--name", "hello-locked",
            "--public-url", "https://hello-locked.main.repo.owner.apps.example.com",
            "--entitlement", "hello-user=hello-users",
        ])

        calls = [(m, p) for (m, p, _b, _q) in rec]
        self.assertIn(("POST", "/providers/oauth2/"), calls)
        self.assertIn(("POST", "/core/applications/"), calls)
        self.assertIn(("POST", "/core/application_entitlements/"), calls)

        sm = next(b for (m, p, b, _q) in rec
                  if p == "/propertymappings/provider/scope/" and m == "POST")
        self.assertIn("app_entitlements(provider.application)", sm["expression"])
        self.assertIn('groups.append("hello-users")', sm["expression"])

        prov = next(b for (m, p, b, _q) in rec
                    if p == "/providers/oauth2/" and m == "POST")
        self.assertIn("map-pk", prov["property_mappings"])
        self.assertEqual(prov["client_type"], "confidential")

        ent = next(b for (m, p, b, _q) in rec
                   if p == "/core/application_entitlements/" and m == "POST")
        self.assertEqual(ent, {"name": "hello-user", "app": "app-uuid"})

        self.assertIn("clientSecretFile = ./hello-locked-client-secret.age;", out)
        self.assertIn('allowedGroups = [ "hello-users" ];', out)
        self.assertIn('issuerUrl = "https://ak.example.com/application/o/hello-locked/";', out)
        self.assertTrue(written)


class MainSharedTest(unittest.TestCase):
    def test_shared_flow(self):
        rec = []

        def dispatch(self, method, path, body=None, query=None):
            rec.append((method, path, body, query))
            if path == "/propertymappings/provider/scope/":
                if method == "POST":
                    return {"pk": "map-pk"}
                q = query or {}
                if q.get("page_size") == 1:
                    return {}
                return {"results": []}
            if path == "/providers/oauth2/" and method == "GET":
                return {"results": [{"pk": 7, "name": "garnix-shared"}]}
            if path == "/providers/oauth2/7/":
                if method == "GET":
                    return {"pk": 7, "name": "garnix-shared",
                            "client_id": "scid", "client_secret": "ssecret",
                            "property_mappings": ["openid"], "redirect_uris": []}
                return {}  # PATCH
            if path == "/core/applications/":
                return {"results": [{"pk": "shared-app", "slug": "garnix-shared",
                                     "provider": 7}]}
            if path == "/core/application_entitlements/":
                return {"results": []} if method == "GET" else {"pk": "ent"}
            return {}

        out, err, written = _run_main(dispatch, [
            "--mode", "shared", "--provider", "garnix-shared",
            "--authentik-url", "https://ak.example.com", "--token", "T",
            "--name", "reports", "--entitlement", "reports-user=reports-users",
            "--public-url", "https://reports.main.repo.owner.apps.example.com",
        ])

        # No new provider/application created in shared mode.
        self.assertNotIn(("POST", "/providers/oauth2/"),
                         [(m, p) for (m, p, _b, _q) in rec])
        self.assertNotIn(("POST", "/core/applications/"),
                         [(m, p) for (m, p, _b, _q) in rec])

        patch = next(b for (m, p, b, _q) in rec
                     if p == "/providers/oauth2/7/" and m == "PATCH")
        self.assertIn("map-pk", patch["property_mappings"])
        self.assertIn("openid", patch["property_mappings"])  # preserved
        self.assertTrue(any(r["url"].endswith("/oauth2/callback")
                            and r["matching_mode"] == "strict"
                            for r in patch["redirect_uris"]))

        ent = next(b for (m, p, b, _q) in rec
                   if p == "/core/application_entitlements/" and m == "POST")
        self.assertEqual(ent, {"name": "reports-user", "app": "shared-app"})

        self.assertIn('mode = "shared";', out)
        self.assertIn('scope = "openid profile email reports";', out)
        self.assertIn('allowedGroups = [ "reports-users" ];', out)
        self.assertIn('issuerUrl = "https://ak.example.com/application/o/garnix-shared/";', out)
        self.assertTrue(written)


class MainValidationTest(unittest.TestCase):
    def test_shared_requires_provider(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit):
                ap.main(["--authentik-url", "https://x", "--token", "T",
                         "--mode", "shared", "--name", "reports",
                         "--public-url", "https://reports.example.com"])

    def test_missing_token_dies(self):
        with mock.patch.dict(os.environ, {}, clear=True), \
             mock.patch.object(ap, "DEFAULT_TOKEN_FILE", "/no/such/authentik-token"), \
             mock.patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit):
                ap.main(["--authentik-url", "https://x", "--name", "reports",
                         "--public-url", "https://reports.example.com"])


class TokenResolveTests(unittest.TestCase):
    def test_explicit_token_wins(self):
        self.assertEqual(ap.resolve_token("X", "/whatever"), "X")

    def test_reads_token_file(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as tf:
            tf.write("  TTT\n")
            path = tf.name
        try:
            self.assertEqual(ap.resolve_token(None, path), "TTT")
        finally:
            os.unlink(path)

    def test_missing_default_returns_none(self):
        with mock.patch.object(ap, "DEFAULT_TOKEN_FILE", "/no/such/default-token"):
            self.assertIsNone(ap.resolve_token(None, "/no/such/default-token"))

    def test_missing_explicit_token_file_dies(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit):
                ap.resolve_token(None, "/no/such/explicit-token")


if __name__ == "__main__":
    unittest.main()
