import importlib.util
import pathlib
import unittest


SCRIPT = pathlib.Path(__file__).with_name("fod-crates-proxy.py")


def load_proxy_module():
    spec = importlib.util.spec_from_file_location("fod_crates_proxy", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class Headers(dict):
    pass


class Request:
    def __init__(self, host: str, path: str):
        self.pretty_host = host
        self.host = host
        self.path = path
        self.scheme = "https"
        self.port = 443
        self.headers = Headers({"host": host, "user-agent": "python-requests"})


class Flow:
    def __init__(self, host: str, path: str):
        self.request = Request(host, path)


class FodCratesProxyTests(unittest.TestCase):
    def test_rewrites_the_crates_api_download_to_the_official_cdn(self):
        proxy = load_proxy_module()
        flow = Flow("crates.io", "/api/v1/crates/capstone-sys/0.14.0/download")

        proxy.request(flow)

        self.assertEqual(flow.request.host, "static.crates.io")
        self.assertEqual(
            flow.request.path,
            "/crates/capstone-sys/0.14.0/download",
        )
        self.assertEqual(flow.request.headers["host"], "static.crates.io")
        self.assertIn("garnix-fod-verifier", flow.request.headers["user-agent"])

    def test_leaves_unrelated_requests_unchanged(self):
        proxy = load_proxy_module()
        flow = Flow("example.com", "/api/v1/crates/foo/1.0.0/download")

        proxy.request(flow)

        self.assertEqual(flow.request.host, "example.com")
        self.assertEqual(flow.request.path, "/api/v1/crates/foo/1.0.0/download")
        self.assertEqual(flow.request.headers["user-agent"], "python-requests")

    def test_leaves_non_download_crates_api_requests_unchanged(self):
        proxy = load_proxy_module()
        flow = Flow("crates.io", "/api/v1/crates/capstone-sys")

        proxy.request(flow)

        self.assertEqual(flow.request.host, "crates.io")
        self.assertEqual(flow.request.path, "/api/v1/crates/capstone-sys")


if __name__ == "__main__":
    unittest.main()
