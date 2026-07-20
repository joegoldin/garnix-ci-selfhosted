# Provisioner Exposure Transaction Design

**Date:** 2026-07-20
**Status:** Design approved; written specification awaiting review
**Parent plan:** `docs/plans/2026-07-20-garnix-hosting-hardening.md`, Tasks 9 and 11

## Context

Task 9 replaces deterministic DNAT port arithmetic with a registry-backed
free-list. The first implementation follows the parent plan's sample code, but
its task review found four unsafe edge cases:

1. A failure after the first firewall mutation can leave unrecorded DNAT rules.
2. A corrupt or truncated registry can be treated as free space or can fail
   after old rules have already been deleted.
3. Duplicate guest ports, especially port 22, can create phantom allocations
   and unstable re-exposure.
4. Splitting `iptables -S` output on whitespace corrupts quoted arguments, and
   the stale-rule matcher can delete unrelated rules.

These are defects in the sample algorithm, not reasons to weaken the hardening
goal. The provisioner runs as root and manages public forwarding, so an expose
request must either commit one coherent registry/firewall state or restore the
previous state.

## Goals

- Allocate the complete requested exposure without collisions.
- Make ordinary command, allocation, and registry-write failures
  transaction-like: either the new state commits or the old state is restored.
- Treat unreadable or structurally invalid registry state as an error before
  any mutation.
- Preserve stable ports where possible.
- Remove stale daemon-shaped rules without touching unrelated firewall rules.
- Keep the existing JSON request/response interface used by the backend.
- Preserve compatibility with well-formed registry files created by the
  current provisioner.

## Non-goals

- Replace iptables with a native nftables implementation.
- Introduce a dedicated persistent firewall chain or an on-disk crash-recovery
  journal.
- Guarantee rollback after `SIGKILL`, kernel failure, or power loss in the
  middle of individual iptables commands. Atomic registry replacement prevents
  truncated committed state; the deployment runtime checklist remains
  responsible for exercising real `iptables-nft` behavior.
- Detect arbitrary non-provisioner host listeners. The host's pinned ephemeral
  range and the provisioner's registry remain the allocation boundary chosen
  by the parent plan.

## Chosen Approach

Use a preflighted compensating transaction under the existing `mutate_lock`.
The transaction has three phases:

1. Strictly read and validate all relevant state, normalize the request, and
   compute every new port assignment without touching disk or iptables.
2. Snapshot the affected live firewall rules, apply checked mutations, and
   record an inverse operation for each successful mutation.
3. Atomically replace the guest registry file as the final commit step. If any
   earlier step fails, execute inverse operations in reverse order and leave
   the old registry file in place.

This is smaller and less deployment-sensitive than introducing new host chains,
while satisfying the review's failure semantics. A preflight-only patch was
rejected because it would still leave partial changes after command or write
failures.

## State Model and Validation

Add one strict loader used by allocation and exposure mutation. A missing file
means no recorded exposure. An existing file is valid only when:

- the top level is an object;
- `ip` is a string;
- `rules` is a list;
- every rule is an object with integer, non-boolean `host` and `guest` fields;
- both ports are in `1..65535`;
- each host port is unique within the file; and
- a host port lies in one of the configured SSH or TCP allocation ranges.

The loader may accept additional object fields for forward compatibility. It
must never silently convert malformed state into an empty allocation. Read
errors, invalid JSON, wrong top-level types, missing fields, invalid field
types, out-of-range ports, and duplicate host ports raise a contextual
`RuntimeError`.

Before allocation, load every `*.json` registry file except the current guest's
file and reject a host port claimed by more than one file. Load and validate the
current guest separately so its old ports can become preferred candidates.
Any validation failure occurs before firewall or filesystem mutation.

`write_exposure` writes JSON to a temporary file in `EXPOSED_DIR`, flushes and
`fsync`s the file, then commits with `os.replace`. An exception before replace
removes the temporary file and preserves the old registry byte-for-byte. The
replace is the transaction's final operation; no fallible mutation follows it.

## Request Normalization and Port 22

Convert requested guest ports to integers, reject ports outside `1..65535`,
and deduplicate them in first-seen order before applying
`TCP_PORTS_PER_VM`. Thus duplicates consume one allocation and produce one
response mapping.

Registry files do not need a new schema discriminator. Existing allocations
are classified by host range:

- guest port 22 in `[SSH_PORT_BASE, TCP_PORT_BASE)` is an SSH exposure;
- any rule in `[TCP_PORT_BASE, PORT_RANGE_END]` is a raw TCP exposure;
- any other host/range combination is invalid state.

When `ssh_expose` is true and raw TCP port 22 is also requested, allocate one
SSH-range host port and one firewall rule. Return that same host port both as
`ssh_port` and as the raw TCP mapping for guest port 22. When `ssh_expose` is
false, raw TCP port 22 is allocated normally from the TCP range. These rules
remove the previous ambiguity while preserving the backend response contract.

## Allocation Preflight

Still under `mutate_lock`:

1. Load and validate the current and other registry files.
2. Build the used-port set from other guests and detect cross-file collisions.
3. Extract the current guest's preferred SSH and per-guest TCP mappings using
   the range classification above.
4. Normalize and deduplicate the request.
5. Allocate the SSH mapping and every unique TCP mapping in memory, including
   the special shared port-22 mapping.
6. Build the complete response and new registry payload.

Range exhaustion, an invalid request, or invalid registry state exits here.
The previous registry and firewall remain unchanged.

## Firewall Rule Parsing and Matching

`_list_rules` invokes `iptables [-t TABLE] -S CHAIN` as a checked command and
parses each returned rule with `shlex.split`. It keeps only rules beginning
with `-A CHAIN`, retaining their original chain order and token boundaries.
Quoted comments therefore round-trip as one argv element.

Only daemon-shaped rules are eligible for automatic cleanup:

- PREROUTING: input interface equals `UPLINK`, protocol is TCP, destination
  port is one of the affected host ports, and jump target is `DNAT`;
- FORWARD: protocol is TCP, destination is the guest's `/32`, a destination
  port is present, and jump target is `ACCEPT`.

UDP rules, non-DNAT rules, rules on another interface, other destination ports,
and non-ACCEPT forwarding rules are preserved. Every matched deletion is
checked. Failure aborts before a replacement rule can be appended behind an
undeleted stale rule.

The affected host-port set is the union of the old recorded ports and all new
ports. The transaction also removes daemon-shaped DNAT rules whose destination
is the current guest IP, so unrecorded leftovers from an earlier failed daemon
run cannot survive re-exposure.

## Mutation and Rollback

Before changing iptables, snapshot the affected parsed rules and their original
one-based positions in each chain. Delete snapshot matches from highest to
lowest position; reversing that journal later reinserts them from lowest to
highest and reconstructs the original order. Then:

1. Delete the affected old/stale PREROUTING and FORWARD rules with checked
   commands, recording enough information to reinsert each at its old position.
2. Add each new DNAT and FORWARD rule with checked commands. After each
   successful add, record its exact checked delete as an inverse.
3. Atomically replace the registry file.

If a delete, add, temporary-file write, `fsync`, or replace fails before the
commit point, execute recorded inverses in reverse order:

- delete each successfully added new rule;
- reinsert each deleted old rule using its original chain position and exact
  parsed argv.

The old registry file was never removed, so a successful rollback restores the
previous logical state. If an inverse itself fails, raise an error containing
both the original failure and the rollback failure; never report exposure
success. This exceptional condition is surfaced for operator intervention and
must not be hidden by `check=False`.

`remove_exposure` uses the same strict validation and checked mutation
machinery. It validates first, removes the matching rules transactionally, and
unlinks the registry only as its final commit step. Invalid state fails before
guest teardown rather than destroying the VM while silently leaving public
forwarding behind.

## Error Contract

The daemon's existing request handler catches raised exceptions and returns an
`{"error": "Type: message"}` response. The new helpers should raise contextual
`RuntimeError`s that name the registry file, port range, or failed firewall
operation without including secret material.

No error path may return a successful `ssh_port` or `tcp_ports` response. A
failed preflight performs zero mutations. A failed apply performs compensating
rollback before the handler returns the error.

## Tests

Extend `provisioner/test_provisionerd_ports.py` test-first. Keep all existing
allocator, registry, rule-filtering, guest-spec, and expose tests. Add focused
regressions for:

- full-allocation exhaustion preserving old registry bytes and producing no
  firewall calls;
- failure after mutation, including registry write failure, removing new rules
  and restoring old rules/state;
- truncated JSON, wrong top-level types, missing fields, non-integer ports,
  out-of-range ports, and duplicate host claims, all with zero side effects;
- atomic registry replacement and temporary-file cleanup on failure;
- first-seen deduplication and stable repeated exposure;
- TCP port 22 with and without `ssh_expose`;
- quoted `iptables -S` arguments;
- preservation of UDP, non-DNAT, other-interface, and unrelated forwarding
  rules;
- deletion of duplicate matching stale rules;
- checked deletion failure aborting before any fresh rule is added; and
- successful rollback preserving original rule order.

The direct unittest suite must first fail for the new behavior and then pass in
full. The Nix check `checks.x86_64-linux.provisionerdPortTests` must also pass.
Python AST parsing, Nix parsing/formatting, Statix, and diff checks remain gates.

## Runtime Verification Deferred to the Parent Plan

The parent plan's deployment checklist must additionally verify, on the real
host:

- repeated exposure keeps stable ports and creates no duplicate rules;
- a deliberately occupied/exhausted test range leaves existing exposure
  untouched;
- generated `iptables-nft` rules match the parser assumptions;
- stale matching DNATs are removed while unrelated UDP/non-DNAT rules survive;
  and
- destroy/re-expose leaves registry files and live firewall rules consistent.
