"""Narrow mitmproxy addon for legacy Nixpkgs cargo-vendor FODs.

Old fetchCargoVendor helpers use crates.io's rate-limited API endpoint. The
official replacement is static.crates.io; both responses are content-addressed
by the checksum in Cargo.lock. Only that exact download route is rewritten.
"""

import re


CRATE_DOWNLOAD = re.compile(r"^/api/v1/crates/([^/]+)/([^/]+)/download$")
USER_AGENT = "garnix-fod-verifier/1 (https://github.com/garnix-io/garnix-ci)"


def request(flow):
    request = flow.request
    if request.pretty_host != "crates.io":
        return

    match = CRATE_DOWNLOAD.fullmatch(request.path)
    if match is None:
        return

    crate, version = match.groups()
    request.scheme = "https"
    request.host = "static.crates.io"
    request.port = 443
    request.path = f"/crates/{crate}/{version}/download"
    request.headers["host"] = "static.crates.io"
    request.headers["user-agent"] = USER_AGENT
