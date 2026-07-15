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

DNSMASQ_HOSTS = os.path.join(STATE_DIR, "dnsmasq-hosts")
SPECS_DIR = os.path.join(STATE_DIR, "specs")
MICROVMS_DIR = "/var/lib/microvms"
GCROOTS_DIR = "/nix/var/nix/gcroots/microvm"

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
        f.write(
            f"""{{
  imports = [ ./guest-profile.nix ];
  networking.hostName = {nix_str(name)};
  microvm.vcpu = {vcpu};
  microvm.mem = {mem};
  microvm.interfaces = [
    {{ type = "bridge"; id = {nix_str(f"gx{vm_id}")}; mac = {nix_str(vm_mac(vm_id))}; bridge = {nix_str(BRIDGE)}; }}
  ];
  garnix.guest.sshPublicKey = {nix_str(pubkey)};
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


def cleanup_vm(name: str):
    """Best-effort teardown of every trace of a guest (idempotent)."""
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


ACTIONS = {"create": do_create, "destroy": do_destroy, "status": do_status}


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
