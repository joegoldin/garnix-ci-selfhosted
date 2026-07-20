#!/usr/bin/env python3
"""Unit tests for provisionerd's host-port allocator + registry. provisionerd
reads PROVISIONER_* env at import time, so required vars are pinned first;
no iptables/network is touched (pure helpers only)."""

import contextlib
import json
import os
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

os.environ.setdefault("PROVISIONER_SOCKET", "/tmp/test-provisioner.sock")
os.environ.setdefault("PROVISIONER_NIXPKGS", "path:/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-src")
os.environ.setdefault("PROVISIONER_MICROVM", "path:/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-src")
os.environ.setdefault("PROVISIONER_GUEST_PROFILE", "/dev/null")
os.environ.setdefault("PROVISIONER_SSH_PUBKEY_FILE", "/dev/null")

import provisionerd as pd


_MISSING = object()


def required_callable(name):
    fn = getattr(pd, name, None)
    if not callable(fn):
        raise AssertionError(f"provisionerd.{name} is not implemented")
    return fn


@contextlib.contextmanager
def patched_pd(**values):
    old = {name: getattr(pd, name, _MISSING) for name in values}
    for name, value in values.items():
        setattr(pd, name, value)
    try:
        yield
    finally:
        for name, value in old.items():
            if value is _MISSING:
                delattr(pd, name)
            else:
                setattr(pd, name, value)


def write_state(directory, name, state):
    path = os.path.join(directory, f"{name}.json")
    with open(path, "w") as f:
        json.dump(state, f)
    return path


class AllocTests(unittest.TestCase):
    def test_lowest_free(self):
        used = {22000, 22001}
        self.assertEqual(required_callable("alloc_host_port")(used, 22000, 31999), 22002)
        self.assertIn(22002, used)

    def test_preferred_wins(self):
        self.assertEqual(
            required_callable("alloc_host_port")(set(), 22000, 31999, preferred=22007),
            22007,
        )

    def test_preferred_taken_falls_back_to_lowest(self):
        self.assertEqual(
            required_callable("alloc_host_port")({22007}, 22000, 31999, preferred=22007),
            22000,
        )

    def test_exhausted_raises(self):
        alloc_host_port = required_callable("alloc_host_port")
        with self.assertRaises(RuntimeError):
            alloc_host_port({22000}, 22000, 22000)


class RegistryTests(unittest.TestCase):
    def test_union_and_exclude(self):
        with tempfile.TemporaryDirectory() as d, patched_pd(EXPOSED_DIR=d):
            with open(os.path.join(d, "garnix-1.json"), "w") as f:
                json.dump({"ip": "10.111.0.11", "rules": [{"host": 22000, "guest": 22}]}, f)
            with open(os.path.join(d, "garnix-2.json"), "w") as f:
                json.dump({"ip": "10.111.0.12", "rules": [{"host": 32000, "guest": 80}]}, f)
            allocated_host_ports = required_callable("allocated_host_ports")
            self.assertEqual(allocated_host_ports(), {22000, 32000})
            self.assertEqual(allocated_host_ports(exclude="garnix-1"), {32000})


class StrictRegistryTests(unittest.TestCase):
    def test_read_exposure_accepts_valid_legacy_shape(self):
        state = {
            "ip": "10.111.0.11",
            "rules": [
                {"host": 22000, "guest": 22},
                {"host": 32000, "guest": 80},
            ],
        }
        with tempfile.TemporaryDirectory() as d, patched_pd(EXPOSED_DIR=d):
            write_state(d, "garnix-1", state)
            self.assertEqual(required_callable("read_exposure")("garnix-1"), state)

    def test_read_exposure_rejects_invalid_shapes(self):
        invalid = [
            [],
            {"rules": []},
            {"ip": 52, "rules": []},
            {"ip": "10.111.0.11", "rules": {}},
            {"ip": "10.111.0.11", "rules": [{"guest": 80}]},
            {"ip": "10.111.0.11", "rules": [{"host": "32000", "guest": 80}]},
            {"ip": "10.111.0.11", "rules": [{"host": 32000, "guest": True}]},
            {"ip": "10.111.0.11", "rules": [{"host": 70000, "guest": 80}]},
            {"ip": "10.111.0.11", "rules": [{"host": 32000, "guest": 0}]},
            {"ip": "10.111.0.11", "rules": [{"host": 22000, "guest": 80}]},
            {
                "ip": "10.111.0.11",
                "rules": [
                    {"host": 32000, "guest": 80},
                    {"host": 32000, "guest": 81},
                ],
            },
            {
                "ip": "10.111.0.11",
                "rules": [
                    {"host": 32000, "guest": 80},
                    {"host": 32001, "guest": 80},
                ],
            },
        ]
        with tempfile.TemporaryDirectory() as d, patched_pd(EXPOSED_DIR=d):
            for index, state in enumerate(invalid):
                name = f"garnix-{index}"
                write_state(d, name, state)
                with self.subTest(state=state), self.assertRaises(RuntimeError):
                    required_callable("read_exposure")(name)

    def test_read_exposure_rejects_truncated_and_unreadable_files(self):
        with tempfile.TemporaryDirectory() as d, patched_pd(EXPOSED_DIR=d):
            path = os.path.join(d, "garnix-1.json")
            with open(path, "w") as f:
                f.write('{"ip":')
            with self.assertRaisesRegex(RuntimeError, "garnix-1.json"):
                required_callable("read_exposure")("garnix-1")
            real_open = open

            def denied(filename, *args, **kwargs):
                if filename == path:
                    raise PermissionError("denied")
                return real_open(filename, *args, **kwargs)

            with mock.patch("builtins.open", side_effect=denied):
                with self.assertRaisesRegex(RuntimeError, "garnix-1.json"):
                    required_callable("read_exposure")("garnix-1")

    def test_allocated_ports_reject_cross_file_collision(self):
        with tempfile.TemporaryDirectory() as d, patched_pd(EXPOSED_DIR=d):
            write_state(
                d,
                "garnix-1",
                {"ip": "10.111.0.11", "rules": [{"host": 32000, "guest": 80}]},
            )
            write_state(
                d,
                "garnix-2",
                {"ip": "10.111.0.12", "rules": [{"host": 32000, "guest": 81}]},
            )
            with self.assertRaisesRegex(RuntimeError, "claimed by"):
                required_callable("allocated_host_ports")()

    def test_write_exposure_is_atomic_and_cleans_failed_temp(self):
        old = b'{"ip":"10.111.0.52","rules":[]}\n'
        with tempfile.TemporaryDirectory() as d, patched_pd(EXPOSED_DIR=d):
            path = os.path.join(d, "garnix-42.json")
            with open(path, "wb") as f:
                f.write(old)
            with mock.patch.object(pd.os, "replace", side_effect=OSError("replace failed")):
                with self.assertRaisesRegex(OSError, "replace failed"):
                    required_callable("write_exposure")(
                        "garnix-42",
                        "10.111.0.52",
                        [{"host": 32000, "guest": 80}],
                    )
            with open(path, "rb") as f:
                self.assertEqual(f.read(), old)
            self.assertEqual(os.listdir(d), ["garnix-42.json"])


class IptablesRuleTests(unittest.TestCase):
    def test_list_rules_returns_only_requested_chain(self):
        calls = []

        def fake_run(cmd, check=True, timeout=None):
            calls.append((cmd, check, timeout))
            return SimpleNamespace(
                stdout=(
                    "-P PREROUTING ACCEPT\n"
                    "-A PREROUTING -i eth0 -p tcp --dport 22000 -j DNAT "
                    "--to-destination 10.111.0.11:22\n"
                    "-A OUTPUT -p tcp --dport 22000 -j DNAT\n"
                )
            )

        with patched_pd(run=fake_run):
            rules = required_callable("_list_rules")("nat", "PREROUTING")

        self.assertEqual(
            rules,
            [
                [
                    "-A",
                    "PREROUTING",
                    "-i",
                    "eth0",
                    "-p",
                    "tcp",
                    "--dport",
                    "22000",
                    "-j",
                    "DNAT",
                    "--to-destination",
                    "10.111.0.11:22",
                ]
            ],
        )
        self.assertEqual(calls, [(["iptables", "-t", "nat", "-S", "PREROUTING"], False, None)])

    def test_flush_host_port_rules_deletes_only_matching_uplink_rules(self):
        rules = [
            ["-A", "PREROUTING", "-i", "eth0", "-p", "tcp", "--dport", "22001", "-j", "DNAT"],
            ["-A", "PREROUTING", "-i", "eth0", "-p", "tcp", "--dport", "22002", "-j", "DNAT"],
            ["-A", "PREROUTING", "-i", "tailscale0", "-p", "tcp", "--dport", "22001", "-j", "DNAT"],
        ]
        calls = []

        def fake_run(cmd, check=True, timeout=None):
            calls.append((cmd, check, timeout))
            return SimpleNamespace(stdout="")

        with patched_pd(_list_rules=lambda table, chain: rules, run=fake_run, UPLINK="eth0"):
            required_callable("flush_host_port_rules")(22001)

        self.assertEqual(
            calls,
            [
                (
                    [
                        "iptables",
                        "-t",
                        "nat",
                        "-D",
                        "PREROUTING",
                        "-i",
                        "eth0",
                        "-p",
                        "tcp",
                        "--dport",
                        "22001",
                        "-j",
                        "DNAT",
                    ],
                    False,
                    None,
                )
            ],
        )

    def test_flush_forward_accepts_deletes_only_guest_accept_rules(self):
        rules = [
            ["-A", "FORWARD", "-p", "tcp", "-d", "10.111.0.52/32", "--dport", "80", "-j", "ACCEPT"],
            ["-A", "FORWARD", "-p", "tcp", "-d", "10.111.0.53/32", "--dport", "80", "-j", "ACCEPT"],
            ["-A", "FORWARD", "-p", "tcp", "-d", "10.111.0.52/32", "--dport", "81", "-j", "DROP"],
        ]
        calls = []

        def fake_run(cmd, check=True, timeout=None):
            calls.append((cmd, check, timeout))
            return SimpleNamespace(stdout="")

        with patched_pd(_list_rules=lambda table, chain: rules, run=fake_run):
            required_callable("flush_forward_accepts")("10.111.0.52")

        self.assertEqual(
            calls,
            [
                (
                    [
                        "iptables",
                        "-D",
                        "FORWARD",
                        "-p",
                        "tcp",
                        "-d",
                        "10.111.0.52/32",
                        "--dport",
                        "80",
                        "-j",
                        "ACCEPT",
                    ],
                    False,
                    None,
                )
            ],
        )


class GuestSpecTests(unittest.TestCase):
    def render_guest_spec(self, terminal_ca=None, terminal_ca_missing=False, guest_cpu=""):
        with tempfile.TemporaryDirectory() as d:
            profile = os.path.join(d, "guest-profile.nix")
            hosting_key = os.path.join(d, "hosting.pub")
            terminal_key = os.path.join(d, "terminal-ca.pub")
            with open(profile, "w") as f:
                f.write("{ ... }: {}\n")
            with open(hosting_key, "w") as f:
                f.write("ssh-ed25519 HOSTING hosting\n")
            terminal_path = ""
            if terminal_ca_missing:
                terminal_path = terminal_key
            elif terminal_ca is not None:
                terminal_path = terminal_key
                with open(terminal_key, "w") as f:
                    f.write(terminal_ca + "\n")
            with patched_pd(
                SPECS_DIR=os.path.join(d, "specs"),
                GUEST_PROFILE=profile,
                SSH_PUBKEY_FILE=hosting_key,
                TERMINAL_CA_PUBKEY_FILE=terminal_path,
                GUEST_CPU=guest_cpu,
            ):
                spec_dir = required_callable("write_spec")("garnix-42", 42, 4, 8192)
                with open(os.path.join(spec_dir, "guest.nix")) as f:
                    return f.read()

    def test_guest_spec_uses_named_tap_without_bridge_attribute(self):
        guest = self.render_guest_spec()
        self.assertIn('{ type = "tap"; id = "gx42"; mac = "02:67:78:00:00:2a"; }', guest)
        self.assertNotIn("bridge =", guest)

    def test_guest_spec_emits_dedicated_terminal_ca(self):
        guest = self.render_guest_spec(terminal_ca="ssh-ed25519 TERMINAL terminal")
        self.assertIn('garnix.guest.sshPublicKey = "ssh-ed25519 HOSTING hosting";', guest)
        self.assertIn(
            'garnix.guest.terminalCaPublicKey = "ssh-ed25519 TERMINAL terminal";',
            guest,
        )

    def test_guest_spec_falls_back_to_hosting_key_for_terminal_ca(self):
        guest = self.render_guest_spec()
        self.assertIn(
            'garnix.guest.terminalCaPublicKey = "ssh-ed25519 HOSTING hosting";',
            guest,
        )

    def test_guest_spec_falls_back_when_terminal_ca_file_is_missing(self):
        guest = self.render_guest_spec(terminal_ca_missing=True)
        self.assertIn(
            'garnix.guest.terminalCaPublicKey = "ssh-ed25519 HOSTING hosting";',
            guest,
        )

    def test_guest_spec_falls_back_when_terminal_ca_file_is_empty(self):
        guest = self.render_guest_spec(terminal_ca="")
        self.assertIn(
            'garnix.guest.terminalCaPublicKey = "ssh-ed25519 HOSTING hosting";',
            guest,
        )

    def test_guest_spec_emits_configured_cpu(self):
        guest = self.render_guest_spec(guest_cpu="IvyBridge")
        self.assertIn('microvm.cpu = "IvyBridge";', guest)

    def test_guest_spec_omits_empty_cpu(self):
        guest = self.render_guest_spec(guest_cpu="")
        self.assertNotIn("microvm.cpu =", guest)


class ExposeTests(unittest.TestCase):
    def expose_without_system_side_effects(self, exposed_dir, req):
        def noop(*args, **kwargs):
            return None

        with patched_pd(
            EXPOSED_DIR=exposed_dir,
            PORT_RANGE_END=41999,
            add_dnat=noop,
            del_dnat=noop,
            flush_host_port_rules=noop,
            flush_forward_accepts=noop,
        ):
            return required_callable("do_expose")(req)

    def test_do_expose_allocates_lowest_ports_free_in_registry(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "garnix-other.json"), "w") as f:
                json.dump(
                    {
                        "ip": "10.111.0.99",
                        "rules": [
                            {"host": 22000, "guest": 22},
                            {"host": 32000, "guest": 8080},
                        ],
                    },
                    f,
                )
            result = self.expose_without_system_side_effects(
                d,
                {"id": 42, "ssh_expose": True, "tcp_ports": [80, 443]},
            )

        self.assertEqual(
            result,
            {
                "ssh_port": 22001,
                "tcp_ports": [
                    {"guest": 80, "host": 32001},
                    {"guest": 443, "host": 32002},
                ],
            },
        )

    def test_do_expose_preserves_this_guests_previous_ports(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "garnix-42.json"), "w") as f:
                json.dump(
                    {
                        "ip": "10.111.0.52",
                        "rules": [
                            {"host": 22007, "guest": 22},
                            {"host": 32009, "guest": 80},
                        ],
                    },
                    f,
                )
            result = self.expose_without_system_side_effects(
                d,
                {"id": 42, "ssh_expose": True, "tcp_ports": [80]},
            )

        self.assertEqual(
            result,
            {
                "ssh_port": 22007,
                "tcp_ports": [{"guest": 80, "host": 32009}],
            },
        )

    def test_do_expose_flushes_guest_and_selected_ports_before_adding_dnat(self):
        events = []

        def noop(*args, **kwargs):
            return None

        def flush_forward(ip):
            events.append(("flush-forward", ip))

        def flush_host(port):
            events.append(("flush-host", port))

        def add_dnat(host, ip, guest):
            events.append(("add", host, ip, guest))

        with tempfile.TemporaryDirectory() as d, patched_pd(
            EXPOSED_DIR=d,
            PORT_RANGE_END=41999,
            add_dnat=add_dnat,
            del_dnat=noop,
            flush_host_port_rules=flush_host,
            flush_forward_accepts=flush_forward,
        ):
            required_callable("do_expose")(
                {"id": 42, "ssh_expose": True, "tcp_ports": [80, 443]}
            )

        self.assertEqual(
            events,
            [
                ("flush-forward", "10.111.0.52"),
                ("flush-host", 22000),
                ("add", 22000, "10.111.0.52", 22),
                ("flush-host", 32000),
                ("add", 32000, "10.111.0.52", 80),
                ("flush-host", 32001),
                ("add", 32001, "10.111.0.52", 443),
            ],
        )


if __name__ == "__main__":
    unittest.main()
