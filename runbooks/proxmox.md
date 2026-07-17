# proxmox runbook

*Template: this is a starting shape based on a real deployment's runbook, with the specifics genericized. Re-derive "What normal looks like" from your own `siemctl digest`/`siemctl search` history once you have a few days of real data.*

Not a single `_source_type` — a Proxmox cluster's nodes (example: 5 nodes
at `10.0.10.20`-`10.0.10.24`) forward as separate sources: `pvestatd`,
`kernel`, `pveproxy`, `corosync`, `pmxcfs`, `postfix`, `pve-firewall`,
`pve-ha-lrm`/`crm`, `pvescheduler`, `spiceproxy`, plus `sshd`/`sudo` (see
those runbooks — same escalation rules apply, not duplicated here).

## What normal looks like

- **`pvestatd`/`kernel` are typically the highest-volume sources** —
  internal telemetry/stats polling, not remarkable at any count.
- **NFS/portmapper to shared storage** (example `192.168.1.15`, ports
  2049/111) from all cluster nodes plus the cluster VIP, continuously —
  shared storage traffic, expected and already documented in your
  environment runbook.
- **Management-network gateway → a node's web UI** (e.g. port 8006) —
  already in your environment runbook, high volume, expected.
- If `corosync`/`pmxcfs` (cluster housekeeping chatter, low
  inter-event frequency, hours+ apart) flap between `new` and
  `gone_silent` in digest coverage, that's usually a digest-window
  artifact rather than a real coverage gap — a source-existence check
  using a much longer lookback window than the volume-comparison window
  avoids this; worth checking whether your SIEM's digest tool decouples
  those two windows.
- **A web-UI/API-ticket PAM auth path is a distinct path from `sshd`:**
  if your cluster's web proxy uses a separate PAM service for its own
  login path, a single auth failure from that path with `rhost=` your
  management-network gateway is consistent with an ordinary mistyped
  web-UI password, not an anomalous source — cross-check against known
  admin-workstation source IPs for your real admin SSH logins to confirm
  they never come from the gateway address itself (if they do, that's a
  more interesting finding).

## Two example findings, not security incidents

These are illustrative of the kind of thing that shows up as log noise
on a Proxmox cluster but is an infra-health matter rather than a SOC
matter — replace with your own once you have real data:

1. **Corosync link flapping:** cluster nodes logging significantly more
   "link ... is down" than "is up" events over a multi-day window —
   asymmetric, suggests a real unresolved network link issue between
   cluster members. Flag to the operator directly as infra health, not a
   SOC matter — but expect the log noise to continue until the underlying
   link issue is fixed.
2. **Mail delivery stuck retrying:** a node repeatedly retrying delivery
   of one message to an external mail server, timing out on port 25
   (outbound 25 likely blocked) — explains a mail-queue source's volume
   "spike" (same message retried many times). Benign repetition, but
   means that node's system mail isn't reaching anyone — worth flagging
   as an operational gap even though it's not a security finding.

## Escalation criteria

- **Benign:** telemetry/NFS/UI traffic above; known, already-flagged
  infra-health noise like the corosync flap and mail-retry examples above
  (don't re-ticket repeatedly); a single web-UI PAM auth failure with
  `rhost` = your management-network gateway — see "What normal looks
  like" above.
- **`incident` to specialist:** non-cluster-internal `pve-firewall`
  deny/reject, an unexpected new-destination entry from a cluster node,
  any auth event on `sshd`/`sudo` (follow those runbooks), or a web-UI
  PAM auth failure that repeats multiple times in a short window
  (brute-force shape) or whose `rhost` is something other than your
  management gateway/a known admin range.

## Canned queries

```bash
siemctl search --query "SELECT hostname,count WHERE _source_type == corosync GROUP BY hostname"
siemctl stats --interval 6h --last 72h
siemctl search --query "SELECT src_ip,dst_ip,dst_port,count WHERE _source_type == pve-firewall GROUP BY src_ip,dst_ip,dst_port"
```
