# Monitoring UX and builder visibility

## Goal

Make both monitoring surfaces show only useful operational information:

- A deployed server's monitor should not repeat sample count or update time
  already visible in its charts.
- The instance Monitoring page should show every machine available to the Nix
  scheduler, currently erdtree and farum-azula, with comparable resource and
  capacity information.

## Deployed-server monitor

Keep the existing CPU and Memory used cards. Remove the Samples and Last update
cards without replacing them. The responsive grid will expand or wrap the two
remaining cards using its existing rules.

The CPU and memory charts, current values, time-axis labels, hover details,
live/stale reporter state, polling, and no-data message remain unchanged. No API
or data-model change is needed.

## Builder monitoring

Add an explicit list of monitoring targets to the self-host backend
configuration. Each target contains a display name, node-exporter URL, supported
systems, and configured Nix `maxJobs`. If the list is absent, the existing
single `nodeExporterUrl` remains the backward-compatible local target.

The backend scrapes targets concurrently and returns a `builders` array from
`GET /api/monitoring`. Each item carries its target metadata and the existing
load, CPU-count, memory, disk, and `scraped` values. One unreachable builder
produces an unavailable card without failing or delaying the other builders or
the rest of the monitoring response.

The frontend replaces the hard-coded `Host (erdtree)` section with a Builders
section. It renders one clearly named resource panel per configured target and
includes its supported system(s) and scheduler capacity. The Instance, Jobs,
Recent builds, and Deployments sections remain unchanged. This shows host
capacity and resource pressure; it does not claim per-job builder attribution,
which the current Nix interface cannot report reliably.

On farum-azula, enable node-exporter and expose its metrics listener only to
erdtree's stable public source address. The backend targets the existing private
domain configuration rather than hard-coding a real domain in either public
repository. Port 9100 must not become generally reachable from the internet.

## Failure and security behavior

- Scrape failures stay local to one target and surface as “couldn't reach” for
  that builder.
- Monitoring remains self-host-only and admin-only.
- Metric target names and URLs are operator configuration, not request input.
- The farum-azula firewall is the authority for the source restriction; the
  exporter has no public allow-all rule.

## Verification

Add focused regressions for:

- Deployed-server monitor: CPU and Memory used are present while Samples and
  Last update are absent.
- Backend monitoring: multiple targets are returned in order; an unreachable
  target degrades independently; Prometheus parsing and resource calculations
  remain correct.
- Frontend monitoring: both configured builders render with metadata and
  resource values; one unavailable builder does not hide the other sections.
- Nix configuration: the builder target list reaches the backend environment,
  and farum-azula's exporter is not globally firewall-open.

Run only those backend/frontend/Nix scopes while iterating. Before deployment,
compile the affected backend and frontend packages; do not rerun unrelated slow
spec groups.

After deployment, verify erdtree and farum-azula both appear, farum-azula's
values change under a native aarch64 build, a failed scrape only marks that
builder unavailable, and port 9100 is rejected from a non-erdtree source.
