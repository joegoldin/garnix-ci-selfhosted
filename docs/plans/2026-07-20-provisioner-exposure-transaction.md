# Transactional Provisioner Exposure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make provisioner DNAT replacement fail closed and transaction-like while preserving stable, collision-free host-port allocation and the backend's existing response contract.

**Architecture:** Split the correction into strict atomic registry persistence, shell-aware checked firewall primitives, and a preflighted compensating exposure transaction. All registry and firewall work remains serialized by `mutate_lock`; the registry replace or unlink is the final commit point, and in-process failures before it roll back live rules.

**Tech Stack:** Python 3 standard library (`json`, `os`, `shlex`, `tempfile`, `unittest`), iptables/iptables-nft command interface, Nix flake checks.

## Global Constraints

- Preserve the request `{"action":"expose","id":Int,"ssh_expose":Bool,"tcp_ports":[Int]}` and response `{"ssh_port":Int|null,"tcp_ports":[{"guest":Int,"host":Int}]}` interfaces.
- Use only Python's standard library; add no runtime dependency.
- Hold the existing `mutate_lock` across preflight, firewall mutation, rollback, and registry commit.
- Existing registry state must be fully validated before the first mutation; invalid or unreadable state fails closed.
- Registry replacement must use a same-directory temporary file, file flush plus `fsync`, and `os.replace` as the final commit operation.
- Parse `iptables -S` with `shlex.split`; mutate only daemon-shaped TCP DNAT and TCP FORWARD ACCEPT rules.
- Every firewall mutation is checked. A failure before commit rolls back successful earlier mutations; rollback failure is surfaced with the original error.
- Deduplicate raw TCP guest ports in first-seen order before the 20-port limit.
- With `ssh_expose = true`, raw TCP guest port 22 shares the SSH-range mapping and firewall rule; without SSH exposure it receives a TCP-range mapping.
- Do not introduce a persistent firewall chain, an on-disk transaction journal, or native nftables code.
- Follow strict red-green-refactor: each new behavior test must fail for its intended reason before production code is written.

## File Map

- `provisioner/provisionerd.py`: strict registry loader/writer, rule parser and mutation journal, allocation preflight, transactional expose/remove operations.
- `provisioner/test_provisionerd_ports.py`: pure unit and simulated-iptables regression suite; no real network or firewall operations.
- `provisioner/default.nix`: existing uncommitted `provisionerdPortTests` flake check; format, lint, and commit it with the test suite.
- `docs/plans/2026-07-20-provisioner-exposure-transaction-design.md`: approved behavioral specification; no further behavior is added by this plan.

---

### Task 1: Strict Registry Validation and Atomic Persistence

**Files:**
- Modify: `provisioner/test_provisionerd_ports.py`
- Modify: `provisioner/provisionerd.py`
- Modify: `provisioner/default.nix`

**Interfaces:**
- Consumes: `_exposure_path(name: str) -> str`, `SSH_PORT_BASE`, `TCP_PORT_BASE`, `PORT_RANGE_END`.
- Produces: `read_exposure(name: str) -> dict | None`, `allocated_host_ports(exclude: str = "") -> set`, `write_exposure(name: str, ip: str, rules: list) -> None`, and `_exposure_rule_kind(host: int, guest: int, path: str) -> str`.

- [ ] **Step 1: Add failing registry validation tests**

Add `mock` and these helpers/tests to `provisioner/test_provisionerd_ports.py`:

```python
from unittest import mock


def write_state(directory, name, state):
    path = os.path.join(directory, f"{name}.json")
    with open(path, "w") as f:
        json.dump(state, f)
    return path


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
            write_state(d, "garnix-1", {"ip": "10.111.0.11", "rules": [{"host": 32000, "guest": 80}]})
            write_state(d, "garnix-2", {"ip": "10.111.0.12", "rules": [{"host": 32000, "guest": 81}]})
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
                        "garnix-42", "10.111.0.52", [{"host": 32000, "guest": 80}]
                    )
            with open(path, "rb") as f:
                self.assertEqual(f.read(), old)
            self.assertEqual(os.listdir(d), ["garnix-42.json"])
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
cd /home/joe/Development/garnix-ci/provisioner
python3 -m unittest \
  test_provisionerd_ports.StrictRegistryTests \
  test_provisionerd_ports.RegistryTests -v
```

Expected: failures for missing `read_exposure`, silent invalid-state handling, collision acceptance, and non-atomic `write_exposure`; imports succeed with zero unexpected errors.

- [ ] **Step 3: Implement strict registry helpers and atomic write**

Add `tempfile` to imports. Move the existing `_exposure_path` above the registry helpers and replace `allocated_host_ports`/`write_exposure` with:

```python
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
```

Remove the later duplicate `_exposure_path` and old `write_exposure` definitions.

- [ ] **Step 4: Run focused and full tests to verify GREEN**

Run:

```bash
cd /home/joe/Development/garnix-ci/provisioner
python3 -m unittest test_provisionerd_ports.StrictRegistryTests test_provisionerd_ports.RegistryTests -v
python3 -m unittest test_provisionerd_ports -v
```

Expected: all focused tests pass; the full suite prints `OK` with no failures, errors, or warnings.

- [ ] **Step 5: Wire and verify the Nix test gate**

Keep the existing uncommitted `checks.provisionerdPortTests` definition in `provisioner/default.nix`, then run:

```bash
cd /home/joe/Development/garnix-ci
nixfmt provisioner/default.nix
statix check provisioner/default.nix
nix-instantiate --parse provisioner/default.nix >/dev/null
git diff --check -- provisioner/default.nix provisioner/provisionerd.py provisioner/test_provisionerd_ports.py
```

Expected: every command exits 0; Statix prints no finding.

- [ ] **Step 6: Commit the independently testable registry slice**

```bash
git add provisioner/default.nix provisioner/provisionerd.py provisioner/test_provisionerd_ports.py
git commit -m "provisioner(state): validate exposure registry and write atomically"
```

Expected: the commit contains exactly those three files; the original hardening plan remains untracked.

---

### Task 2: Checked, Shell-Aware Firewall Mutation Primitives

**Files:**
- Modify: `provisioner/test_provisionerd_ports.py`
- Modify: `provisioner/provisionerd.py`

**Interfaces:**
- Consumes: `run(cmd, check=True, timeout=None)`, `_dnat_specs(host_port, guest_ip, guest_port)`.
- Produces: `_list_rules(table, chain: str) -> list[list[str]]`, `_affected_firewall_rules(host_ports: set, guest_ip: str) -> list[tuple]`, `_delete_snapshots(snapshots: list, journal: list)`, `_append_rule(table, chain, rest, journal)`, and `_rollback(journal)`.

- [ ] **Step 1: Add a simulated iptables runner and failing parser/matcher tests**

Add `shlex` and `subprocess` imports to the test file, then add this test-local simulator:

```python
class FakeIptables:
    def __init__(self, nat=None, forward=None, fail_when=None):
        self.rules = {
            ("nat", "PREROUTING"): list(nat or []),
            (None, "FORWARD"): list(forward or []),
        }
        self.calls = []
        self.fail_when = fail_when or (lambda cmd: False)

    def run(self, cmd, check=True, timeout=None):
        self.calls.append((list(cmd), check, timeout))
        table = None
        index = 1
        if cmd[index:index + 2] == ["-t", "nat"]:
            table = "nat"
            index += 2
        op = cmd[index]
        chain = cmd[index + 1]
        args = list(cmd[index + 2:])
        key = (table, chain)
        if op == "-S":
            return SimpleNamespace(
                stdout="".join(shlex.join(parts) + "\n" for parts in self.rules[key]),
                returncode=0,
            )
        if self.fail_when(cmd):
            if check:
                raise subprocess.CalledProcessError(1, cmd, output="injected failure")
            return SimpleNamespace(stdout="injected failure", returncode=1)
        if op == "-D":
            target = ["-A", chain] + args
            try:
                self.rules[key].remove(target)
            except ValueError:
                if check:
                    raise subprocess.CalledProcessError(1, cmd, output="rule absent")
                return SimpleNamespace(stdout="rule absent", returncode=1)
        elif op == "-A":
            self.rules[key].append(["-A", chain] + args)
        elif op == "-I":
            position = int(args[0])
            self.rules[key].insert(position - 1, ["-A", chain] + args[1:])
        else:
            raise AssertionError(f"unexpected iptables operation: {cmd}")
        return SimpleNamespace(stdout="", returncode=0)
```

Replace the old whitespace-parser and broad flush assertions with:

```python
class IptablesRuleTests(unittest.TestCase):
    def test_list_rules_preserves_quoted_arguments_and_checks_command(self):
        def fake_run(cmd, check=True, timeout=None):
            self.assertTrue(check)
            return SimpleNamespace(
                stdout=(
                    '-A PREROUTING -i eth0 -p tcp --dport 22000 '
                    '-m comment --comment "legacy tenant" -j DNAT '
                    '--to-destination 10.111.0.11:22\n'
                ),
                returncode=0,
            )

        with patched_pd(run=fake_run):
            rules = required_callable("_list_rules")("nat", "PREROUTING")
        self.assertIn("legacy tenant", rules[0])
        self.assertNotIn('"legacy', rules[0])

    def test_affected_rules_are_narrow_and_keep_original_positions(self):
        matching = ["-A", "PREROUTING", "-i", "eth0", "-p", "tcp", "--dport", "22001", "-j", "DNAT", "--to-destination", "10.111.0.52:80"]
        stale_by_ip = ["-A", "PREROUTING", "-i", "eth0", "-p", "tcp", "--dport", "22999", "-j", "DNAT", "--to-destination", "10.111.0.52:81"]
        udp = ["-A", "PREROUTING", "-i", "eth0", "-p", "udp", "--dport", "22001", "-j", "DNAT", "--to-destination", "10.111.0.52:80"]
        non_dnat = ["-A", "PREROUTING", "-i", "eth0", "-p", "tcp", "--dport", "22001", "-j", "ACCEPT"]
        other_interface = ["-A", "PREROUTING", "-i", "tailscale0", "-p", "tcp", "--dport", "22001", "-j", "DNAT", "--to-destination", "10.111.0.52:80"]
        forward = ["-A", "FORWARD", "-p", "tcp", "-d", "10.111.0.52/32", "--dport", "80", "-j", "ACCEPT"]
        unrelated_forward = ["-A", "FORWARD", "-p", "udp", "-d", "10.111.0.52/32", "--dport", "80", "-j", "ACCEPT"]
        fake = FakeIptables(
            nat=[udp, matching, non_dnat, other_interface, stale_by_ip],
            forward=[unrelated_forward, forward],
        )
        with patched_pd(run=fake.run, UPLINK="eth0"):
            snapshots = required_callable("_affected_firewall_rules")({22001}, "10.111.0.52")
        self.assertEqual(
            snapshots,
            [
                ("nat", "PREROUTING", 2, matching[2:]),
                ("nat", "PREROUTING", 5, stale_by_ip[2:]),
                (None, "FORWARD", 2, forward[2:]),
            ],
        )

    def test_checked_delete_failure_does_not_hide_error(self):
        rule = ["-A", "PREROUTING", "-i", "eth0", "-p", "tcp", "--dport", "22001", "-j", "DNAT", "--to-destination", "10.111.0.52:80"]
        fake = FakeIptables(nat=[rule], fail_when=lambda cmd: "-D" in cmd)
        journal = []
        with patched_pd(run=fake.run):
            with self.assertRaises(subprocess.CalledProcessError):
                required_callable("_delete_snapshots")(
                    [("nat", "PREROUTING", 1, rule[2:])], journal
                )
        self.assertEqual(journal, [])
        self.assertEqual(fake.rules[("nat", "PREROUTING")], [rule])

    def test_duplicate_matching_rules_delete_and_rollback_in_original_order(self):
        duplicate = ["-A", "PREROUTING", "-i", "eth0", "-p", "tcp", "--dport", "22001", "-j", "DNAT", "--to-destination", "10.111.0.52:80"]
        unrelated = ["-A", "PREROUTING", "-p", "udp", "--dport", "22001", "-j", "ACCEPT"]
        original = [duplicate, unrelated, duplicate]
        fake = FakeIptables(nat=original)
        with patched_pd(run=fake.run, UPLINK="eth0"):
            snapshots = required_callable("_affected_firewall_rules")(
                {22001}, "10.111.0.52"
            )
            journal = []
            required_callable("_delete_snapshots")(snapshots, journal)
            self.assertEqual(fake.rules[("nat", "PREROUTING")], [unrelated])
            required_callable("_rollback")(journal)
        self.assertEqual(fake.rules[("nat", "PREROUTING")], original)
```

- [ ] **Step 2: Run the firewall tests and verify RED**

Run:

```bash
cd /home/joe/Development/garnix-ci/provisioner
python3 -m unittest test_provisionerd_ports.IptablesRuleTests -v
```

Expected: failures show quoted arguments are split, unrelated rules are selected, checked journal helpers are absent, or deletions suppress failure. No real iptables command runs.

- [ ] **Step 3: Implement parser, narrow matchers, and mutation journal**

Add `shlex` to production imports. Replace `_list_rules` and both broad flush
helpers, and add the snapshot/journal primitives below:

```python
def _list_rules(table, chain: str) -> list:
    cmd = ["iptables"]
    if table:
        cmd += ["-t", table]
    cmd += ["-S", chain]
    res = run(cmd, check=True)
    rules = []
    for line in (res.stdout or "").splitlines():
        try:
            parts = shlex.split(line)
        except ValueError as error:
            raise RuntimeError(f"cannot parse iptables rule in {chain}: {line!r}") from error
        if parts[:2] == ["-A", chain]:
            rules.append(parts)
    return rules


def _rule_value(parts: list, flag: str):
    try:
        index = parts.index(flag)
    except ValueError:
        return None
    return parts[index + 1] if index + 1 < len(parts) else None


def _is_affected_dnat(parts: list, host_ports: set, guest_ip: str) -> bool:
    destination = _rule_value(parts, "--to-destination") or ""
    destination_ip = destination.rsplit(":", 1)[0]
    dport = _rule_value(parts, "--dport")
    return (
        _rule_value(parts, "-i") == UPLINK
        and _rule_value(parts, "-p") == "tcp"
        and _rule_value(parts, "-j") == "DNAT"
        and dport is not None
        and (dport in {str(port) for port in host_ports} or destination_ip == guest_ip)
    )


def _is_affected_forward(parts: list, guest_ip: str) -> bool:
    return (
        _rule_value(parts, "-p") == "tcp"
        and _rule_value(parts, "-d") in {guest_ip, f"{guest_ip}/32"}
        and _rule_value(parts, "--dport") is not None
        and _rule_value(parts, "-j") == "ACCEPT"
    )


def _affected_firewall_rules(host_ports: set, guest_ip: str) -> list:
    snapshots = []
    for position, parts in enumerate(_list_rules("nat", "PREROUTING"), start=1):
        if _is_affected_dnat(parts, host_ports, guest_ip):
            snapshots.append(("nat", "PREROUTING", position, parts[2:]))
    for position, parts in enumerate(_list_rules(None, "FORWARD"), start=1):
        if _is_affected_forward(parts, guest_ip):
            snapshots.append((None, "FORWARD", position, parts[2:]))
    return snapshots


def _iptables_command(table, operation: str, chain: str, rest: list) -> list:
    cmd = ["iptables"]
    if table:
        cmd += ["-t", table]
    return cmd + [operation, chain] + rest


def _delete_snapshots(snapshots: list, journal: list):
    ordered = sorted(snapshots, key=lambda item: (item[0] or "", item[1], -item[2]))
    for table, chain, position, rest in ordered:
        run(_iptables_command(table, "-D", chain, rest), check=True)
        journal.append(("insert", table, chain, position, rest))


def _append_rule(table, chain: str, rest: list, journal: list):
    run(_iptables_command(table, "-A", chain, rest), check=True)
    journal.append(("delete", table, chain, 0, rest))


def _rollback(journal: list):
    failures = []
    for operation, table, chain, position, rest in reversed(journal):
        inverse_rest = [str(position)] + rest if operation == "insert" else rest
        iptables_operation = "-I" if operation == "insert" else "-D"
        try:
            run(_iptables_command(table, iptables_operation, chain, inverse_rest), check=True)
        except Exception as error:
            failures.append(str(error))
    if failures:
        raise RuntimeError("firewall rollback failed: " + "; ".join(failures))


def flush_host_port_rules(host_port: int):
    snapshots = [
        snapshot
        for snapshot in _affected_firewall_rules({host_port}, "")
        if snapshot[0] == "nat"
    ]
    journal = []
    try:
        _delete_snapshots(snapshots, journal)
    except BaseException:
        _rollback(journal)
        raise


def flush_forward_accepts(guest_ip: str):
    snapshots = [
        snapshot
        for snapshot in _affected_firewall_rules(set(), guest_ip)
        if snapshot[0] is None
    ]
    journal = []
    try:
        _delete_snapshots(snapshots, journal)
    except BaseException:
        _rollback(journal)
        raise
```

Keep `_dnat_specs`, `_iptables`, `add_dnat`, and `del_dnat` temporarily because
the pre-Task-3 expose/remove paths still call them. The two compatibility flush
wrappers above keep that intermediate commit runnable and make their deletions
narrow, checked, and locally reversible; Task 3 removes all five wrappers.

- [ ] **Step 4: Verify parser/mutation GREEN and full regression safety**

Run:

```bash
cd /home/joe/Development/garnix-ci/provisioner
python3 -m unittest test_provisionerd_ports.IptablesRuleTests -v
python3 -m unittest test_provisionerd_ports -v
```

Expected: all tests pass and print `OK`; fake runner assertions prove every mutation uses `check=True`.

- [ ] **Step 5: Parse, diff-check, and commit**

Run:

```bash
cd /home/joe/Development/garnix-ci
python3 -c "import ast; ast.parse(open('provisioner/provisionerd.py').read()); print('PARSE_OK')"
git diff --check -- provisioner/provisionerd.py provisioner/test_provisionerd_ports.py
git add provisioner/provisionerd.py provisioner/test_provisionerd_ports.py
git commit -m "provisioner(firewall): parse and mutate exposure rules safely"
```

Expected: `PARSE_OK`; diff check exits 0; the commit contains exactly the daemon and test file.

---

### Task 3: Preflighted Exposure Transaction and Port Identity

**Files:**
- Modify: `provisioner/test_provisionerd_ports.py`
- Modify: `provisioner/provisionerd.py`

**Interfaces:**
- Consumes: Task 1 strict state helpers and Task 2 firewall snapshot/journal helpers.
- Produces: `_normalize_tcp_ports(values) -> list[int]`, `_plan_exposure(name, ip, ssh_expose, tcp_values) -> dict`, transactional `do_expose(req) -> dict`, and transactional `remove_exposure(name) -> None`.

- [ ] **Step 1: Adapt the expose test harness to simulated live rules**

Replace `ExposeTests.expose_without_system_side_effects` with:

```python
    def expose_with_firewall(self, exposed_dir, req, firewall=None, **settings):
        firewall = firewall or FakeIptables()
        values = {
            "EXPOSED_DIR": exposed_dir,
            "SSH_PORT_BASE": 22000,
            "TCP_PORT_BASE": 32000,
            "PORT_RANGE_END": 41999,
            "UPLINK": "eth0",
            "run": firewall.run,
        }
        values.update(settings)
        with patched_pd(**values):
            result = required_callable("do_expose")(req)
        return result, firewall
```

Replace the three existing expose methods with these exact fake-firewall
versions:

```python
    def test_do_expose_allocates_lowest_ports_free_in_registry(self):
        with tempfile.TemporaryDirectory() as d:
            write_state(
                d,
                "garnix-other",
                {
                    "ip": "10.111.0.99",
                    "rules": [
                        {"host": 22000, "guest": 22},
                        {"host": 32000, "guest": 8080},
                    ],
                },
            )
            result, _ = self.expose_with_firewall(
                d, {"id": 42, "ssh_expose": True, "tcp_ports": [80, 443]}
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
        old_nat = [
            ["-A", "PREROUTING", "-i", "eth0", "-p", "tcp", "--dport", "22007", "-j", "DNAT", "--to-destination", "10.111.0.52:22"],
            ["-A", "PREROUTING", "-i", "eth0", "-p", "tcp", "--dport", "32009", "-j", "DNAT", "--to-destination", "10.111.0.52:80"],
        ]
        old_forward = [
            ["-A", "FORWARD", "-p", "tcp", "-d", "10.111.0.52/32", "--dport", "22", "-j", "ACCEPT"],
            ["-A", "FORWARD", "-p", "tcp", "-d", "10.111.0.52/32", "--dport", "80", "-j", "ACCEPT"],
        ]
        with tempfile.TemporaryDirectory() as d:
            write_state(
                d,
                "garnix-42",
                {
                    "ip": "10.111.0.52",
                    "rules": [
                        {"host": 22007, "guest": 22},
                        {"host": 32009, "guest": 80},
                    ],
                },
            )
            result, _ = self.expose_with_firewall(
                d,
                {"id": 42, "ssh_expose": True, "tcp_ports": [80]},
                firewall=FakeIptables(nat=old_nat, forward=old_forward),
            )
        self.assertEqual(
            result,
            {"ssh_port": 22007, "tcp_ports": [{"guest": 80, "host": 32009}]},
        )

    def test_do_expose_replaces_stale_guest_rules_and_preserves_unrelated_rules(self):
        unrelated_nat = ["-A", "PREROUTING", "-i", "eth0", "-p", "udp", "--dport", "32000", "-j", "ACCEPT"]
        stale_nat = ["-A", "PREROUTING", "-i", "eth0", "-p", "tcp", "--dport", "32999", "-j", "DNAT", "--to-destination", "10.111.0.52:9000"]
        unrelated_forward = ["-A", "FORWARD", "-p", "udp", "-d", "10.111.0.52/32", "--dport", "9000", "-j", "ACCEPT"]
        stale_forward = ["-A", "FORWARD", "-p", "tcp", "-d", "10.111.0.52/32", "--dport", "9000", "-j", "ACCEPT"]
        firewall = FakeIptables(
            nat=[unrelated_nat, stale_nat],
            forward=[unrelated_forward, stale_forward],
        )
        with tempfile.TemporaryDirectory() as d:
            _, firewall = self.expose_with_firewall(
                d,
                {"id": 42, "ssh_expose": True, "tcp_ports": [80, 443]},
                firewall=firewall,
            )
        self.assertIn(unrelated_nat, firewall.rules[("nat", "PREROUTING")])
        self.assertNotIn(stale_nat, firewall.rules[("nat", "PREROUTING")])
        self.assertIn(unrelated_forward, firewall.rules[(None, "FORWARD")])
        self.assertNotIn(stale_forward, firewall.rules[(None, "FORWARD")])
```

- [ ] **Step 2: Add failing preflight, deduplication, and port-22 tests**

Add:

```python
    def test_exhaustion_preflight_preserves_old_state_and_makes_no_firewall_calls(self):
        with tempfile.TemporaryDirectory() as d:
            path = write_state(d, "garnix-42", {"ip": "10.111.0.52", "rules": [{"host": 32000, "guest": 80}]})
            with open(path, "rb") as f:
                before = f.read()
            firewall = FakeIptables()
            with patched_pd(
                EXPOSED_DIR=d,
                SSH_PORT_BASE=22000,
                TCP_PORT_BASE=32000,
                PORT_RANGE_END=32000,
                UPLINK="eth0",
                run=firewall.run,
            ):
                with self.assertRaisesRegex(RuntimeError, "no free host port"):
                    required_callable("do_expose")(
                        {"id": 42, "ssh_expose": False, "tcp_ports": [80, 443]}
                    )
            with open(path, "rb") as f:
                self.assertEqual(f.read(), before)
            self.assertEqual(firewall.calls, [])

    def test_duplicate_tcp_ports_get_one_stable_mapping(self):
        with tempfile.TemporaryDirectory() as d:
            first, firewall = self.expose_with_firewall(
                d, {"id": 42, "ssh_expose": False, "tcp_ports": [80, 80, 443, 80]}
            )
            second, firewall = self.expose_with_firewall(
                d,
                {"id": 42, "ssh_expose": False, "tcp_ports": [80, 80, 443]},
                firewall=firewall,
            )
        self.assertEqual(first["tcp_ports"], [{"guest": 80, "host": 32000}, {"guest": 443, "host": 32001}])
        self.assertEqual(second, first)

    def test_tcp_22_shares_ssh_mapping_when_ssh_is_exposed(self):
        with tempfile.TemporaryDirectory() as d:
            result, _ = self.expose_with_firewall(
                d, {"id": 42, "ssh_expose": True, "tcp_ports": [22, 22]}
            )
            with open(os.path.join(d, "garnix-42.json")) as f:
                state = json.load(f)
        self.assertEqual(result, {"ssh_port": 22000, "tcp_ports": [{"guest": 22, "host": 22000}]})
        self.assertEqual(state["rules"], [{"host": 22000, "guest": 22}])

    def test_tcp_22_uses_tcp_range_without_ssh_exposure(self):
        with tempfile.TemporaryDirectory() as d:
            result, _ = self.expose_with_firewall(
                d, {"id": 42, "ssh_expose": False, "tcp_ports": [22]}
            )
        self.assertEqual(result, {"ssh_port": None, "tcp_ports": [{"guest": 22, "host": 32000}]})
```

- [ ] **Step 3: Add failing rollback and corrupt-state zero-side-effect tests**

Add:

```python
    def test_registry_write_failure_rolls_back_exact_live_rules(self):
        old_nat = [
            ["-A", "PREROUTING", "-p", "tcp", "--dport", "9999", "-j", "ACCEPT"],
            ["-A", "PREROUTING", "-i", "eth0", "-p", "tcp", "--dport", "32009", "-j", "DNAT", "--to-destination", "10.111.0.52:80"],
            ["-A", "PREROUTING", "-p", "udp", "--dport", "32009", "-j", "ACCEPT"],
        ]
        old_forward = [
            ["-A", "FORWARD", "-p", "tcp", "-d", "10.111.0.52/32", "--dport", "80", "-j", "ACCEPT"]
        ]
        firewall = FakeIptables(nat=old_nat, forward=old_forward)
        with tempfile.TemporaryDirectory() as d:
            path = write_state(d, "garnix-42", {"ip": "10.111.0.52", "rules": [{"host": 32009, "guest": 80}]})
            with open(path, "rb") as f:
                before = f.read()
            with patched_pd(EXPOSED_DIR=d, run=firewall.run, UPLINK="eth0"):
                with mock.patch.object(pd, "write_exposure", side_effect=OSError("disk full")):
                    with self.assertRaisesRegex(OSError, "disk full"):
                        required_callable("do_expose")(
                            {"id": 42, "ssh_expose": False, "tcp_ports": [80]}
                        )
            with open(path, "rb") as f:
                self.assertEqual(f.read(), before)
        self.assertEqual(firewall.rules[("nat", "PREROUTING")], old_nat)
        self.assertEqual(firewall.rules[(None, "FORWARD")], old_forward)

    def test_add_failure_rolls_back_deleted_rules_in_original_order(self):
        old_nat = [
            ["-A", "PREROUTING", "-p", "tcp", "--dport", "9998", "-j", "ACCEPT"],
            ["-A", "PREROUTING", "-i", "eth0", "-p", "tcp", "--dport", "32009", "-j", "DNAT", "--to-destination", "10.111.0.52:80"],
            ["-A", "PREROUTING", "-p", "tcp", "--dport", "9999", "-j", "ACCEPT"],
        ]
        firewall = FakeIptables(nat=old_nat, fail_when=lambda cmd: "-A" in cmd)
        with tempfile.TemporaryDirectory() as d:
            write_state(d, "garnix-42", {"ip": "10.111.0.52", "rules": [{"host": 32009, "guest": 80}]})
            with patched_pd(EXPOSED_DIR=d, run=firewall.run, UPLINK="eth0"):
                with self.assertRaises(subprocess.CalledProcessError):
                    required_callable("do_expose")(
                        {"id": 42, "ssh_expose": False, "tcp_ports": [80]}
                    )
        self.assertEqual(firewall.rules[("nat", "PREROUTING")], old_nat)

    def test_invalid_registry_fails_before_firewall_side_effects(self):
        invalid = [
            '{"ip":',
            "[]",
            '{"ip":"10.111.0.52","rules":[{"guest":80}]}',
            '{"ip":"10.111.0.52","rules":[{"host":"32000","guest":80}]}',
            '{"ip":"10.111.0.99","rules":[]}',
        ]
        for index, body in enumerate(invalid):
            with self.subTest(body=body), tempfile.TemporaryDirectory() as d:
                path = os.path.join(d, "garnix-42.json")
                with open(path, "w") as f:
                    f.write(body)
                firewall = FakeIptables()
                with patched_pd(EXPOSED_DIR=d, run=firewall.run):
                    with self.assertRaises(RuntimeError):
                        required_callable("do_expose")(
                            {"id": 42, "ssh_expose": False, "tcp_ports": [80]}
                        )
                self.assertEqual(firewall.calls, [])
                with open(path) as f:
                    self.assertEqual(f.read(), body)

    def test_delete_failure_aborts_before_new_rule_is_added(self):
        old = ["-A", "PREROUTING", "-i", "eth0", "-p", "tcp", "--dport", "32009", "-j", "DNAT", "--to-destination", "10.111.0.52:80"]
        firewall = FakeIptables(nat=[old], fail_when=lambda cmd: "-D" in cmd)
        with tempfile.TemporaryDirectory() as d:
            write_state(d, "garnix-42", {"ip": "10.111.0.52", "rules": [{"host": 32009, "guest": 80}]})
            with patched_pd(EXPOSED_DIR=d, run=firewall.run, UPLINK="eth0"):
                with self.assertRaises(subprocess.CalledProcessError):
                    required_callable("do_expose")(
                        {"id": 42, "ssh_expose": False, "tcp_ports": [80]}
                    )
        mutations = [call[0] for call in firewall.calls if "-S" not in call[0]]
        self.assertTrue(mutations)
        self.assertTrue(all("-A" not in cmd for cmd in mutations))

    def test_rollback_failure_reports_both_failures(self):
        old = ["-A", "PREROUTING", "-i", "eth0", "-p", "tcp", "--dport", "32009", "-j", "DNAT", "--to-destination", "10.111.0.52:80"]
        failures = {"add": False}

        def fail_when(cmd):
            if "-A" in cmd:
                failures["add"] = True
                return True
            return failures["add"] and "-I" in cmd

        firewall = FakeIptables(nat=[old], fail_when=fail_when)
        with tempfile.TemporaryDirectory() as d:
            write_state(d, "garnix-42", {"ip": "10.111.0.52", "rules": [{"host": 32009, "guest": 80}]})
            with patched_pd(EXPOSED_DIR=d, run=firewall.run, UPLINK="eth0"):
                with self.assertRaisesRegex(RuntimeError, "rollback also failed"):
                    required_callable("do_expose")(
                        {"id": 42, "ssh_expose": False, "tcp_ports": [80]}
                    )

    def test_remove_exposure_validates_before_mutating(self):
        firewall = FakeIptables()
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "garnix-42.json")
            with open(path, "w") as f:
                f.write('{"ip":')
            with patched_pd(EXPOSED_DIR=d, run=firewall.run):
                with self.assertRaises(RuntimeError):
                    required_callable("remove_exposure")("garnix-42")
            self.assertEqual(firewall.calls, [])
            self.assertTrue(os.path.exists(path))

    def test_remove_exposure_commits_rule_and_registry_removal(self):
        old_nat = [
            ["-A", "PREROUTING", "-i", "eth0", "-p", "tcp", "--dport", "32009", "-j", "DNAT", "--to-destination", "10.111.0.52:80"]
        ]
        old_forward = [
            ["-A", "FORWARD", "-p", "tcp", "-d", "10.111.0.52/32", "--dport", "80", "-j", "ACCEPT"]
        ]
        firewall = FakeIptables(nat=old_nat, forward=old_forward)
        with tempfile.TemporaryDirectory() as d:
            path = write_state(d, "garnix-42", {"ip": "10.111.0.52", "rules": [{"host": 32009, "guest": 80}]})
            with patched_pd(EXPOSED_DIR=d, run=firewall.run, UPLINK="eth0"):
                required_callable("remove_exposure")("garnix-42")
            self.assertFalse(os.path.exists(path))
        self.assertEqual(firewall.rules[("nat", "PREROUTING")], [])
        self.assertEqual(firewall.rules[(None, "FORWARD")], [])

    def test_remove_exposure_unlink_failure_restores_live_rules(self):
        old_nat = [
            ["-A", "PREROUTING", "-i", "eth0", "-p", "tcp", "--dport", "32009", "-j", "DNAT", "--to-destination", "10.111.0.52:80"]
        ]
        old_forward = [
            ["-A", "FORWARD", "-p", "tcp", "-d", "10.111.0.52/32", "--dport", "80", "-j", "ACCEPT"]
        ]
        firewall = FakeIptables(nat=old_nat, forward=old_forward)
        with tempfile.TemporaryDirectory() as d:
            path = write_state(d, "garnix-42", {"ip": "10.111.0.52", "rules": [{"host": 32009, "guest": 80}]})
            with patched_pd(EXPOSED_DIR=d, run=firewall.run, UPLINK="eth0"):
                with mock.patch.object(pd.os, "unlink", side_effect=OSError("unlink failed")):
                    with self.assertRaisesRegex(OSError, "unlink failed"):
                        required_callable("remove_exposure")("garnix-42")
            self.assertTrue(os.path.exists(path))
        self.assertEqual(firewall.rules[("nat", "PREROUTING")], old_nat)
        self.assertEqual(firewall.rules[(None, "FORWARD")], old_forward)
```

- [ ] **Step 4: Run all new expose tests and verify RED**

Run:

```bash
cd /home/joe/Development/garnix-ci/provisioner
python3 -m unittest test_provisionerd_ports.ExposeTests -v
```

Expected: failures reproduce preflight mutation, duplicate/port-22 ambiguity, non-transactional write/add failure, invalid-state fail-open behavior, or unchecked deletion. No unexpected import error and no real firewall access.

- [ ] **Step 5: Implement request normalization and complete allocation preflight**

Add:

```python
def _normalize_tcp_ports(values) -> list:
    ports = []
    seen = set()
    for raw in values:
        if isinstance(raw, bool):
            raise RuntimeError("TCP guest port must be an integer in 1-65535")
        try:
            port = int(raw)
        except (TypeError, ValueError) as error:
            raise RuntimeError("TCP guest port must be an integer in 1-65535") from error
        if not 1 <= port <= 65535:
            raise RuntimeError(f"TCP guest port {port} is outside 1-65535")
        if port not in seen:
            seen.add(port)
            ports.append(port)
    return ports[:TCP_PORTS_PER_VM]


def _plan_exposure(name: str, ip: str, ssh_expose: bool, tcp_values) -> dict:
    old_state = read_exposure(name)
    if old_state is not None and old_state["ip"] != ip:
        raise RuntimeError(
            f"exposure registry {_exposure_path(name)} has IP {old_state['ip']}, expected {ip}"
        )
    used = allocated_host_ports()
    preferred_ssh = None
    preferred_tcp = {}
    if old_state is not None:
        for rule in old_state["rules"]:
            used.remove(rule["host"])
            if _exposure_rule_kind(rule["host"], rule["guest"], _exposure_path(name)) == "ssh":
                preferred_ssh = rule["host"]
            else:
                preferred_tcp[rule["guest"]] = rule["host"]
    tcp_ports = _normalize_tcp_ports(tcp_values)
    new_rules = []
    tcp_result = []
    ssh_port = None
    if ssh_expose:
        ssh_port = alloc_host_port(
            used, SSH_PORT_BASE, TCP_PORT_BASE - 1, preferred=preferred_ssh
        )
        new_rules.append({"host": ssh_port, "guest": 22})
    for guest in tcp_ports:
        if guest == 22 and ssh_port is not None:
            tcp_result.append({"guest": 22, "host": ssh_port})
            continue
        host = alloc_host_port(
            used, TCP_PORT_BASE, PORT_RANGE_END, preferred=preferred_tcp.get(guest)
        )
        new_rules.append({"host": host, "guest": guest})
        tcp_result.append({"guest": guest, "host": host})
    return {
        "old_state": old_state,
        "new_rules": new_rules,
        "ssh_port": ssh_port,
        "tcp_result": tcp_result,
        "response": {"ssh_port": ssh_port, "tcp_ports": tcp_result},
        "ip": ip,
    }
```

Calling `allocated_host_ports()` without exclusion validates cross-file uniqueness before current ports are removed from `used`.

- [ ] **Step 6: Implement transactional expose and remove paths**

Add the shared failure helper and replace `do_expose`/`remove_exposure`:

```python
def _rollback_after_failure(journal: list, original: BaseException):
    try:
        _rollback(journal)
    except Exception as rollback_error:
        raise RuntimeError(
            f"exposure update failed: {original}; rollback also failed: {rollback_error}"
        ) from original


def do_expose(req: dict) -> dict:
    vm_id = int(req["id"])
    name = vm_name(vm_id)
    ip = vm_ip(vm_id)
    ssh_expose = bool(req.get("ssh_expose", False))
    with mutate_lock:
        plan = _plan_exposure(name, ip, ssh_expose, req.get("tcp_ports", []))
        old_rules = [] if plan["old_state"] is None else plan["old_state"]["rules"]
        affected_ports = {rule["host"] for rule in old_rules + plan["new_rules"]}
        snapshots = _affected_firewall_rules(affected_ports, ip)
        journal = []
        try:
            _delete_snapshots(snapshots, journal)
            for rule in plan["new_rules"]:
                for table, chain, rest in _dnat_specs(rule["host"], ip, rule["guest"]):
                    _append_rule(table, chain, rest, journal)
            write_exposure(name, ip, plan["new_rules"])
        except BaseException as error:
            _rollback_after_failure(journal, error)
            raise
    log.info("exposed %s: ssh_port=%s tcp=%s", name, plan["ssh_port"], plan["tcp_result"])
    return plan["response"]


def remove_exposure(name: str):
    state = read_exposure(name)
    ip = state["ip"] if state is not None else vm_ip_from_name(name)
    if not ip:
        return
    host_ports = set() if state is None else {rule["host"] for rule in state["rules"]}
    snapshots = _affected_firewall_rules(host_ports, ip)
    journal = []
    try:
        _delete_snapshots(snapshots, journal)
        if state is not None:
            os.unlink(_exposure_path(name))
    except BaseException as error:
        _rollback_after_failure(journal, error)
        raise
```

Remove the old pre-mutation `remove_exposure`, broad flush calls, sequential
allocation loop, and now-unused `_iptables`, `add_dnat`, and `del_dnat`.
Remove obsolete comments claiming contiguous per-VM blocks.

- [ ] **Step 7: Run all direct and Nix tests**

Run:

```bash
cd /home/joe/Development/garnix-ci/provisioner
python3 -m unittest test_provisionerd_ports -v
cd /home/joe/Development/garnix-ci
nix build .#checks.x86_64-linux.provisionerdPortTests
python3 -c "import ast; ast.parse(open('provisioner/provisionerd.py').read()); print('PARSE_OK')"
nixfmt provisioner/default.nix
statix check provisioner/default.nix
nix-instantiate --parse provisioner/default.nix >/dev/null
git diff --check -- provisioner/default.nix provisioner/provisionerd.py provisioner/test_provisionerd_ports.py
```

Expected: direct unittest prints `OK`; Nix build exits 0 and creates the check result; `PARSE_OK`; formatting, Statix, Nix parse, and diff checks all exit 0 with no findings.

- [ ] **Step 8: Self-review required invariants**

Inspect the final diff and explicitly confirm in the task report:

```text
preflight exhaustion -> zero run() calls and unchanged registry bytes
invalid registry -> zero run() calls and unchanged file
every mutation -> check=True
delete failure -> no fresh -A command
write/add failure -> new rules removed; old rules and order restored
rollback failure -> combined error returned
duplicates -> one first-seen mapping
SSH + TCP 22 -> one SSH-range rule, two response references
TCP 22 only -> TCP-range rule
quoted comments -> one argv token
UDP/non-DNAT/other-interface rules -> untouched
registry replace -> temporary + fsync + os.replace final
```

- [ ] **Step 9: Commit the transactional behavior**

```bash
git add provisioner/provisionerd.py provisioner/test_provisionerd_ports.py
git commit -m "provisioner(expose): make DNAT replacement transactional"
```

Expected: the commit contains exactly the daemon and test file. Task 9 and Task 11 are now ready for a combined immutable-range review; deployment/runtime proof remains in the parent plan's Tasks 17–20.
