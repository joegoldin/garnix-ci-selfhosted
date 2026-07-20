#!/usr/bin/env python3
"""garnix-provisionerd: create/destroy/status for local microvm.nix guests.

The garnix backend's LocalProvisioner (backend/src/Garnix/LocalProvisioner.hs)
speaks newline-delimited JSON over a unix socket, one request per connection:

  {"action": "create", "id": <int32>, "vcpu": N, "mem": MiB} -> {"ipv4": "10.111.0.X"}
  {"action": "destroy", "id": <int32>}                       -> {}
  {"action": "status", "id": <int32>}                        -> {"status": "running"|"off"}

Errors are returned as {"error": "..."}. The int32 id is the backend's
"hetzner id"; the guest is named garnix-<id> with a deterministic MAC/IP so
the dnsmasq DHCP reservation survives daemon restarts without extra state.

Runs as root (systemd unit garnix-provisionerd from provisioner/nixos-module.nix,
which supplies all PROVISIONER_* environment variables). Pure stdlib.
"""

import json
import logging
import os
import re
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

log = logging.getLogger("garnix-provisionerd")

SOCKET_PATH = os.environ["PROVISIONER_SOCKET"]
SOCKET_GROUP = os.environ.get("PROVISIONER_SOCKET_GROUP", "garnix")
STATE_DIR = os.environ.get("PROVISIONER_STATE_DIR", "/var/lib/garnix-provisioner")
BRIDGE = os.environ.get("PROVISIONER_BRIDGE", "garnixbr0")
# First three octets of the guest subnet, e.g. "10.111.0".
SUBNET_PREFIX = os.environ.get("PROVISIONER_SUBNET_PREFIX", "10.111.0")
NIXPKGS_FLAKE = os.environ["PROVISIONER_NIXPKGS"]
MICROVM_FLAKE = os.environ["PROVISIONER_MICROVM"]
GUEST_PROFILE = os.environ["PROVISIONER_GUEST_PROFILE"]
SSH_PUBKEY_FILE = os.environ["PROVISIONER_SSH_PUBKEY_FILE"]
# Dedicated web-terminal CA public key (finding H3). Guests trust THIS as their
# TrustedUserCAKeys, not the hosting key. Optional: if unset/absent/empty we
# fall back to the hosting pubkey in write_spec, so guests stay evaluable and
# keep trusting the hosting key as CA (pre-H3 behaviour / ExecStartPre fallback).
TERMINAL_CA_PUBKEY_FILE = os.environ.get("PROVISIONER_TERMINAL_CA_PUBKEY_FILE", "")
# Full URL of the garnix stats-ingest endpoint (POST /api/hosts/stats). Empty
# by default; when set, guests push their CPU/RAM there every ~20s. Injected
# into each guest's config so the reporter knows where to POST.
STATS_URL = os.environ.get("PROVISIONER_STATS_URL", "")
# Optional fixed QEMU CPU model for guests (microvm.cpu). Empty = -cpu host.
GUEST_CPU = os.environ.get("PROVISIONER_GUEST_CPU", "")

DNSMASQ_HOSTS = os.path.join(STATE_DIR, "dnsmasq-hosts")
SPECS_DIR = os.path.join(STATE_DIR, "specs")
EXPOSED_DIR = os.path.join(STATE_DIR, "exposed")
MICROVMS_DIR = "/var/lib/microvms"
GCROOTS_DIR = "/nix/var/nix/gcroots/microvm"

# Public-facing NIC that inbound DNAT traffic arrives on, plus the host-port
# bases for SSH / raw-TCP exposure (see do_expose + nixos-module.nix).
UPLINK = os.environ.get("PROVISIONER_UPLINK", "eth0")
SSH_PORT_BASE = int(os.environ.get("PROVISIONER_SSH_PORT_BASE", "22000"))
TCP_PORT_BASE = int(os.environ.get("PROVISIONER_TCP_PORT_BASE", "32000"))
# Each VM gets a contiguous block of this many host ports for tcp exposure.
TCP_PORTS_PER_VM = 20
# Inclusive top of the host DNAT port range (exposePortRange.to on the host).
PORT_RANGE_END = int(os.environ.get("PROVISIONER_PORT_RANGE_END", "41999"))

SSH_WAIT_SECONDS = 120

# create/destroy mutate shared state (dnsmasq hosts file, microvm state dirs)
# and are slow; serialize them. status stays lock-free so the backend's
# 1s-interval polls aren't blocked behind a multi-minute create.
mutate_lock = threading.Lock()


def vm_name(vm_id: int) -> str:
    return f"garnix-{vm_id}"


def vm_mac(vm_id: int) -> str:
    # Locally-administered prefix 02:67:78 ("gx") + the low 3 bytes of the id.
    b = vm_id & 0xFFFFFF
    return f"02:67:78:{(b >> 16) & 0xFF:02x}:{(b >> 8) & 0xFF:02x}:{b & 0xFF:02x}"


def vm_ip(vm_id: int) -> str:
    # .10-.249; the id space in practice is a small monotonic sequence, so
    # collisions (ids 240 apart alive at once) are not a realistic concern
    # for a single-host pool.
    return f"{SUBNET_PREFIX}.{10 + vm_id % 240}"


def run(cmd, check=True, timeout=None):
    log.info("+ %s", " ".join(cmd))
    return subprocess.run(
        cmd, check=check, timeout=timeout, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )


def nix_str(s: str) -> str:
    """Render a python string as a Nix double-quoted string literal."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("${", "\\${") + '"'


def write_spec(name: str, vm_id: int, vcpu: int, mem: int) -> str:
    """Write the per-VM flake (flake.nix + guest.nix) and return the spec dir."""
    with open(SSH_PUBKEY_FILE) as f:
        pubkey = f.read().strip()
    # Web-terminal CA pubkey (H3). Fall back to the hosting pubkey if the
    # dedicated CA pubkey file is unset/absent/empty, so guests stay evaluable
    # and keep trusting the hosting key as CA until the pool is recycled.
    terminal_ca_pubkey = pubkey
    if TERMINAL_CA_PUBKEY_FILE:
        try:
            with open(TERMINAL_CA_PUBKEY_FILE) as f:
                _tca = f.read().strip()
            if _tca:
                terminal_ca_pubkey = _tca
        except FileNotFoundError:
            pass
    spec_dir = os.path.join(SPECS_DIR, name)
    os.makedirs(spec_dir, exist_ok=True)
    # Copy the shared guest profile into the flake tree and import it
    # relatively: `microvm -c` evaluates the flake in pure mode, where an
    # absolute /nix/store import path is forbidden.
    shutil.copyfile(GUEST_PROFILE, os.path.join(spec_dir, "guest-profile.nix"))
    with open(os.path.join(spec_dir, "flake.nix"), "w") as f:
        f.write(
            f"""{{
  description = "garnix-provisioned microVM {name}";
  inputs = {{
    nixpkgs.url = {nix_str(NIXPKGS_FLAKE)};
    microvm.url = {nix_str(MICROVM_FLAKE)};
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  }};
  outputs = {{ self, nixpkgs, microvm }}: {{
    nixosConfigurations.{nix_str(name)} = nixpkgs.lib.nixosSystem {{
      system = "x86_64-linux";
      modules = [ microvm.nixosModules.microvm ./guest.nix ];
    }};
  }};
}}
"""
        )
    with open(os.path.join(spec_dir, "guest.nix"), "w") as f:
        # `type = "tap"` (not "bridge"): the bridge-helper netdev creates an
        # anonymous kernel-named tap the host can't target. A named tap
        # (gx<id>, created by microvm-tap-interfaces@) lets the host enslave
        # it to the bridge as an ISOLATED port (see nixos-module.nix), which
        # blocks guest<->guest at L2 regardless of bridge-nf-call-* sysctls.
        cpu_line = f"  microvm.cpu = {nix_str(GUEST_CPU)};\n" if GUEST_CPU else ""
        f.write(
            f"""{{
  imports = [ ./guest-profile.nix ];
  networking.hostName = {nix_str(name)};
  microvm.vcpu = {vcpu};
  microvm.mem = {mem};
{cpu_line}  microvm.interfaces = [
    {{ type = "tap"; id = {nix_str(f"gx{vm_id}")}; mac = {nix_str(vm_mac(vm_id))}; }}
  ];
  garnix.guest.sshPublicKey = {nix_str(pubkey)};
  garnix.guest.terminalCaPublicKey = {nix_str(terminal_ca_pubkey)};
  garnix.guest.statsReportUrl = {nix_str(STATS_URL)};
  garnix.guest.provisionerId = {vm_id};
}}
"""
        )
    return spec_dir


def dnsmasq_reserve(name: str, mac: str, ip: str):
    dnsmasq_drop(name)
    with open(DNSMASQ_HOSTS, "a") as f:
        f.write(f"{mac},{ip},{name},infinite\n")
    run(["systemctl", "reload-or-restart", "dnsmasq.service"], check=False)


def dnsmasq_drop(name: str):
    try:
        with open(DNSMASQ_HOSTS) as f:
            lines = f.readlines()
    except FileNotFoundError:
        lines = []
    kept = [l for l in lines if not re.match(rf"^[^,]*,[^,]*,{re.escape(name)}(,|$)", l.strip())]
    if kept != lines:
        with open(DNSMASQ_HOSTS, "w") as f:
            f.writelines(kept)
        run(["systemctl", "reload-or-restart", "dnsmasq.service"], check=False)


def wait_for_ssh(ip: str, timeout: float):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((ip, 22), timeout=2):
                return
        except OSError:
            time.sleep(2)
    raise RuntimeError(f"guest {ip} did not open tcp/22 within {int(timeout)}s")


def _iptables(op: str, table, chain: str, rest: list):
    cmd = ["iptables"]
    if table:
        cmd += ["-t", table]
    cmd += [op, chain] + rest
    # Deletes may fail (rule absent); adds run only after a delete, so they stay
    # unique. Never fatal — a failed rule shouldn't abort a deploy.
    run(cmd, check=False)


def _dnat_specs(host_port: int, guest_ip: str, guest_port: int):
    """(table, chain, rest-args) for the PREROUTING DNAT + FORWARD ACCEPT."""
    return [
        (
            "nat",
            "PREROUTING",
            ["-i", UPLINK, "-p", "tcp", "--dport", str(host_port),
             "-j", "DNAT", "--to-destination", f"{guest_ip}:{guest_port}"],
        ),
        (
            None,
            "FORWARD",
            ["-p", "tcp", "-d", guest_ip, "--dport", str(guest_port), "-j", "ACCEPT"],
        ),
    ]


def add_dnat(host_port: int, guest_ip: str, guest_port: int):
    for table, chain, rest in _dnat_specs(host_port, guest_ip, guest_port):
        _iptables("-D", table, chain, rest)  # idempotent: clear a stale copy first
        _iptables("-A", table, chain, rest)


def del_dnat(host_port: int, guest_ip: str, guest_port: int):
    for table, chain, rest in _dnat_specs(host_port, guest_ip, guest_port):
        _iptables("-D", table, chain, rest)


def _list_rules(table, chain: str) -> list:
    """Parse `iptables [-t table] -S <chain>` into arg-lists (['-A', chain, ...])."""
    cmd = ["iptables"]
    if table:
        cmd += ["-t", table]
    cmd += ["-S", chain]
    res = run(cmd, check=False)
    rules = []
    for line in (res.stdout or "").splitlines():
        parts = line.split()
        if parts[:2] == ["-A", chain]:
            rules.append(parts)
    return rules


def flush_host_port_rules(host_port: int):
    """Delete EVERY uplink PREROUTING rule for this host port, whatever guest
    it pointed at — stale DNATs from crashed daemons or prior tenants must
    never linger behind a fresh expose."""
    for parts in _list_rules("nat", "PREROUTING"):
        if (
            "--dport" in parts
            and parts[parts.index("--dport") + 1] == str(host_port)
            and "-i" in parts
            and parts[parts.index("-i") + 1] == UPLINK
        ):
            run(["iptables", "-t", "nat", "-D"] + parts[1:], check=False)


def flush_forward_accepts(guest_ip: str):
    """Delete every FORWARD ACCEPT aimed at this guest IP (stale entries from
    an earlier VM that held the same deterministic IP)."""
    for parts in _list_rules(None, "FORWARD"):
        if (
            "-d" in parts
            and parts[parts.index("-d") + 1] == f"{guest_ip}/32"
            and parts[-1] == "ACCEPT"
        ):
            run(["iptables", "-D"] + parts[1:], check=False)


def _exposure_path(name: str) -> str:
    return os.path.join(EXPOSED_DIR, f"{name}.json")


def _is_port(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 1 <= value <= 65535


def _exposure_rule_kind(host: int, guest: int, path: str) -> str:
    if SSH_PORT_BASE <= host < TCP_PORT_BASE:
        if guest != 22:
            raise RuntimeError(f"invalid SSH-range rule in {path}: guest port must be 22")
        return "ssh"
    if TCP_PORT_BASE <= host <= PORT_RANGE_END:
        return "tcp"
    raise RuntimeError(f"host port {host} in {path} is outside the configured exposure ranges")


def read_exposure(name: str):
    path = _exposure_path(name)
    try:
        with open(path) as f:
            state = json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as error:
        raise RuntimeError(f"cannot read exposure registry {path}: {error}") from error
    if not isinstance(state, dict) or not isinstance(state.get("ip"), str):
        raise RuntimeError(f"invalid exposure registry {path}: expected object with string ip")
    raw_rules = state.get("rules")
    if not isinstance(raw_rules, list):
        raise RuntimeError(f"invalid exposure registry {path}: rules must be a list")
    rules = []
    seen_hosts = set()
    seen_tcp_guests = set()
    seen_ssh = False
    for raw in raw_rules:
        if not isinstance(raw, dict) or not _is_port(raw.get("host")) or not _is_port(raw.get("guest")):
            raise RuntimeError(f"invalid exposure rule in {path}: host and guest must be integer ports")
        host = raw["host"]
        guest = raw["guest"]
        if host in seen_hosts:
            raise RuntimeError(f"duplicate host port {host} in {path}")
        kind = _exposure_rule_kind(host, guest, path)
        if kind == "ssh":
            if seen_ssh:
                raise RuntimeError(f"duplicate SSH exposure in {path}")
            seen_ssh = True
        elif guest in seen_tcp_guests:
            raise RuntimeError(f"duplicate TCP guest port {guest} in {path}")
        else:
            seen_tcp_guests.add(guest)
        seen_hosts.add(host)
        rules.append({"host": host, "guest": guest})
    return {"ip": state["ip"], "rules": rules}


def allocated_host_ports(exclude: str = "") -> set:
    owners = {}
    try:
        entries = sorted(os.listdir(EXPOSED_DIR))
    except FileNotFoundError:
        return set()
    except OSError as error:
        raise RuntimeError(f"cannot list exposure registry {EXPOSED_DIR}: {error}") from error
    for filename in entries:
        if not filename.endswith(".json") or filename == f"{exclude}.json":
            continue
        name = filename.removesuffix(".json")
        state = read_exposure(name)
        if state is None:
            continue
        for rule in state["rules"]:
            host = rule["host"]
            if host in owners:
                raise RuntimeError(
                    f"host port {host} is claimed by both {owners[host]} and {filename}"
                )
            owners[host] = filename
    return set(owners)


def alloc_host_port(used: set, lo: int, hi: int, preferred=None) -> int:
    """Lowest free port in [lo, hi], preferring this VM's previous port so
    re-exposing stays stable. Marks the result used."""
    if preferred is not None and lo <= preferred <= hi and preferred not in used:
        used.add(preferred)
        return preferred
    for port in range(lo, hi + 1):
        if port not in used:
            used.add(port)
            return port
    raise RuntimeError(f"no free host port in {lo}-{hi}")


def remove_exposure(name: str):
    """Delete any DNAT rules previously added for this VM, and the state file."""
    try:
        with open(_exposure_path(name)) as f:
            state = json.load(f)
    except (FileNotFoundError, ValueError):
        return
    ip = state.get("ip", vm_ip_from_name(name))
    for rule in state.get("rules", []):
        del_dnat(int(rule["host"]), ip, int(rule["guest"]))
    try:
        os.unlink(_exposure_path(name))
    except FileNotFoundError:
        pass


def write_exposure(name: str, ip: str, rules: list):
    os.makedirs(EXPOSED_DIR, exist_ok=True)
    path = _exposure_path(name)
    fd, temporary = tempfile.mkstemp(prefix=f".{name}.", suffix=".tmp", dir=EXPOSED_DIR)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump({"ip": ip, "rules": rules}, f)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def vm_ip_from_name(name: str) -> str:
    m = re.match(r"^garnix-(\d+)$", name)
    return vm_ip(int(m.group(1))) if m else ""


def cleanup_vm(name: str):
    """Best-effort teardown of every trace of a guest (idempotent)."""
    remove_exposure(name)
    run(["systemctl", "stop", f"microvm@{name}.service"], check=False)
    shutil.rmtree(os.path.join(MICROVMS_DIR, name), ignore_errors=True)
    shutil.rmtree(os.path.join(SPECS_DIR, name), ignore_errors=True)
    for root in (name, f"booted-{name}"):
        try:
            os.unlink(os.path.join(GCROOTS_DIR, root))
        except FileNotFoundError:
            pass
    dnsmasq_drop(name)


def do_create(req: dict) -> dict:
    vm_id = int(req["id"])
    vcpu = int(req["vcpu"])
    mem = int(req["mem"])
    name = vm_name(vm_id)
    mac = vm_mac(vm_id)
    ip = vm_ip(vm_id)
    with mutate_lock:
        # A retried create after a partial failure must not trip over remnants.
        cleanup_vm(name)
        spec_dir = write_spec(name, vm_id, vcpu, mem)
        dnsmasq_reserve(name, mac, ip)
        try:
            create = run(["microvm", "-c", name, "-f", f"path:{spec_dir}"], check=False, timeout=1800)
            if create.returncode != 0:
                raise RuntimeError(f"microvm -c {name} failed: {create.stdout.strip()[-2000:]}")
            start = run(["systemctl", "start", f"microvm@{name}.service"], check=False)
            if start.returncode != 0:
                raise RuntimeError(f"systemctl start microvm@{name} failed: {start.stdout.strip()[-2000:]}")
            wait_for_ssh(ip, SSH_WAIT_SECONDS)
        except BaseException:
            cleanup_vm(name)
            raise
    log.info("created %s (%s, %s vcpu, %s MiB) at %s", name, mac, vcpu, mem, ip)
    return {"ipv4": ip}


def do_destroy(req: dict) -> dict:
    name = vm_name(int(req["id"]))
    with mutate_lock:
        cleanup_vm(name)
    log.info("destroyed %s", name)
    return {}


def do_status(req: dict) -> dict:
    name = vm_name(int(req["id"]))
    is_active = subprocess.run(
        ["systemctl", "is-active", f"microvm@{name}.service"], stdout=subprocess.PIPE, text=True
    )
    state = is_active.stdout.strip()
    return {"status": "running" if state == "active" else "off"}


def do_expose(req: dict) -> dict:
    """Publish a guest's SSH and/or tcp ports on the host via DNAT. Host ports
    come from a free-list over the exposure registry (EXPOSED_DIR), preferring
    the VM's previous ports so re-exposing is stable; any stale rule on a
    chosen host port is flushed before the fresh DNAT is added. Response:
      {"ssh_port": Int|null, "tcp_ports": [{"guest": Int, "host": Int}, ...]}."""
    vm_id = int(req["id"])
    name = vm_name(vm_id)
    ip = vm_ip(vm_id)
    ssh_expose = bool(req.get("ssh_expose", False))
    tcp_ports = [int(p) for p in req.get("tcp_ports", [])]
    with mutate_lock:
        # Remember this VM's previous allocation before wiping it.
        preferred = {}
        prev_ssh = None
        try:
            with open(_exposure_path(name)) as f:
                prev = json.load(f)
            for rule in prev.get("rules", []):
                if int(rule["guest"]) == 22:
                    prev_ssh = int(rule["host"])
                else:
                    preferred[int(rule["guest"])] = int(rule["host"])
        except (FileNotFoundError, ValueError):
            pass
        # Re-exposing replaces prior rules (idempotent), including any strays
        # aimed at this guest IP from an earlier tenant of the same id slot.
        remove_exposure(name)
        flush_forward_accepts(ip)
        used = allocated_host_ports(exclude=name)
        rules = []
        ssh_port = None
        if ssh_expose:
            ssh_port = alloc_host_port(used, SSH_PORT_BASE, TCP_PORT_BASE - 1, preferred=prev_ssh)
            flush_host_port_rules(ssh_port)
            add_dnat(ssh_port, ip, 22)
            rules.append({"host": ssh_port, "guest": 22})
        tcp_result = []
        for guest in tcp_ports[:TCP_PORTS_PER_VM]:
            host_port = alloc_host_port(used, TCP_PORT_BASE, PORT_RANGE_END, preferred=preferred.get(guest))
            flush_host_port_rules(host_port)
            add_dnat(host_port, ip, guest)
            rules.append({"host": host_port, "guest": guest})
            tcp_result.append({"guest": guest, "host": host_port})
        write_exposure(name, ip, rules)
    log.info("exposed %s: ssh_port=%s tcp=%s", name, ssh_port, tcp_result)
    return {"ssh_port": ssh_port, "tcp_ports": tcp_result}


ACTIONS = {"create": do_create, "destroy": do_destroy, "status": do_status, "expose": do_expose}


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            line = self.rfile.readline()
            if not line.strip():
                return
            req = json.loads(line)
            action = ACTIONS.get(req.get("action"))
            if action is None:
                resp = {"error": f"unknown action: {req.get('action')!r}"}
            else:
                resp = action(req)
        except Exception as e:  # noqa: BLE001 -- report anything to the client
            log.exception("request failed")
            resp = {"error": f"{type(e).__name__}: {e}"}
        try:
            self.wfile.write(json.dumps(resp).encode() + b"\n")
        except BrokenPipeError:
            pass


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    # Slow creates hold connections open; keep plenty of backlog for status polls.
    request_queue_size = 64


def main():
    logging.basicConfig(stream=sys.stderr, level=logging.INFO, format="%(levelname)s %(message)s")
    os.makedirs(SPECS_DIR, exist_ok=True)
    os.makedirs(EXPOSED_DIR, exist_ok=True)
    if not os.path.exists(DNSMASQ_HOSTS):
        open(DNSMASQ_HOSTS, "a").close()
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass
    server = Server(SOCKET_PATH, Handler)
    os.chmod(SOCKET_PATH, 0o660)
    shutil.chown(SOCKET_PATH, user="root", group=SOCKET_GROUP)
    log.info("listening on %s (bridge %s, subnet %s.0/24)", SOCKET_PATH, BRIDGE, SUBNET_PREFIX)
    server.serve_forever()


if __name__ == "__main__":
    main()
