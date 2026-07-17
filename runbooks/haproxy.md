# haproxy runbook

*Template: this is a starting shape based on a real deployment's runbook, with the specifics genericized (RFC5737 documentation-range IPs throughout, not real observed addresses). Re-derive "What normal looks like" from your own `siemctl digest`/`siemctl search` history once you have a few days of real data.*

Source: `haproxy` (e.g. a pfSense package or standalone instance,
reverse-proxying to some internal web UI — example
`frontend=example_reverse_proxy`, `backend=192.168.1.12`). If your
firewall/proxy logs multiple ways (its own local syslog, plus HAProxy
logging directly to a remote UDP socket), keep in mind these paths can
fail independently — a healthy local syslog daemon doesn't guarantee
HAProxy's own logging is working. See the "known issue" section below.

## What normal looks like

**TLS probes against any internet-reachable reverse proxy tend to
dominate alert volume** on a small deployment — concentration warnings on
this source are expected, not a sign of trouble, if every probing IP
traces back to a known internet-wide scanner range and nobody is
targeting your proxy specifically. Overall volume is typically low
(dozens-to-low-hundreds/day for a homelab-scale deployment), so a real
spike is easy to spot against that baseline.

## Known-benign: internet-scanner TLS probes

Illustrative example (replace with your own observed ranges once you have
real data — use `rdap-lookup <ip>` per below to characterize each one):

| Range | Count (72h) | Notes |
|---|---|---|
| `198.51.100.0/25` | ~20 | Example: mass internet-wide TLS scanning service |
| `198.51.100.128/25` | ~4 | Example: known scanner range |
| `203.0.113.0/24` | ~3 (repeated across separate days) | Example: crossed a repeat-visit threshold — suppression candidate once a range shows up on 3+ separate days |

Seed new ranges into `config/rules/suppress.toml` as *commented* entries
for a review/tuning role to enable once they've earned it (e.g. after
crossing a repeat-visit threshold like the example above) — don't
auto-suppress on first sighting.

## Known-benign: registered office/admin access

Unlike the scanner table above (TLS probes, no successful handshake),
this is *successful* traffic against your backend from a legitimate admin
source — don't lump it in with the scanner ranges or your suppression
config (that typically only covers the TLS-probe rule; successful admin
traffic doesn't trip that rule at all, it trips a raw volume-spike check
instead, which usually has no per-IP suppression mechanism of its own).

| Range | Owner | Notes |
|---|---|---|
| `192.0.2.0/24` | *(your organization)* | Example: operator's office/VPN egress. A large burst of `Connect from` lines over several hours during a session is normal browser/API polling over a persistent connection, not a flood — verify against actual usage before treating volume alone as suspicious. |

**How to verify a new/unrecognized IP against this table:** `rdap-lookup
<ip>` (a small helper script — see `scripts/rdap-lookup`'s own docstring
for the safety rationale) — check the printed `name`/`org` for a
registrant that plausibly explains admin traffic (e.g. your own
organization or ISP). This is what distinguishes "operator's own network,
just verify the registration" from "outside prober, treat as suspicious"
when the traffic itself (successful requests, no probing pattern) doesn't
otherwise decide it. Only treat an IP as benign this way if it also
*behaves* like admin traffic (hits your known backend specifically, no
unusual path) — a registered-org IP doing something scan-like is still
worth escalating. (Operator-only equivalent, if investigating by hand
outside your automated roles: `curl -sL https://rdap.org/ip/<ip>`.)

## Escalation criteria

- **Benign, close/ack:** TLS-probe from a scanner range above, no
  successful handshake, low-frequency. Also: any-volume traffic against
  your known backend from a range in the office/admin table above,
  provided it doesn't otherwise look scan-like (see verification note
  above) — a volume spike alone from one of these ranges is not
  incident-worthy, unlike from an unrecognized IP.
- **`noise` to your tuning role:** a *new* scanner range repeats 3+ times
  across separate days — suppression candidate.
- **`incident` to specialist (≥medium):** anything that isn't a TLS
  handshake failure against your known backend — a different backend, a
  successful-looking request, or any rule other than the TLS-probe one
  firing — **and** the source IP isn't RDAP-verifiable against the
  office/admin table above. Also a probing IP outside known ranges
  escalating beyond a TLS probe (e.g. to an actual HTTP request), or an
  office/admin-range IP whose traffic pattern doesn't otherwise look like
  normal admin access.

## Canned queries

```bash
siemctl search --query "SELECT src_ip,count WHERE _source_type == haproxy GROUP BY src_ip LIMIT 20"
siemctl search --query "SELECT timestamp,src_ip,backend WHERE _source_type == haproxy AND NOT cidr_match(src_ip, '198.51.100.0/24')"
siemctl stats --source haproxy --interval 1h --last 24h
```

## Known issue: silent log-emission stall (no crash, no config change)

If HAProxy logs *directly* to your SIEM over its own UDP socket (`log
<siem-host>:5514 local0 info` in `haproxy.cfg`'s `global` section) rather
than through the local syslog daemon, be aware this path can silently
stop emitting without any crash or config change — a healthy local
syslogd is not evidence this path is working, and an unrelated syslogd
incident is not evidence for or against this failure mode either.

Symptom: `siemctl digest` shows `haproxy` `gone_silent`/`drop` for hours
while the process itself is healthy — no crash, no restart visible in
`ps`/system logs, and the process is still actively serving real requests
(connection counters climbing via the admin socket, an established
session visible in the firewall's state table). The process simply
stopped emitting to its logging socket at some point, silently.

**How to confirm this specific failure** (vs. a real network/forwarding
gap): send a manual test packet from the proxy's own shell mimicking a
haproxy line, and confirm it's ingested immediately:

```bash
printf '<134>1 %s your-firewall-host haproxy 1 - - TEST' "$(date -Iseconds)" | nc -u -w1 <siem-host> 5514
```

then `siemctl search --query "SELECT timestamp,message WHERE
_source_type == haproxy" --after <ts>` on the SIEM side. If the test
packet arrives but real traffic doesn't produce anything despite live
requests (check the HAProxy admin socket for request-counter growth, or
`tcpdump` on the SIEM-facing interface for the absence of haproxy's own
packets), the network path is fine and the fault is HAProxy's internal
logging state.

**Fix:** a graceful reload of the HAProxy config. This is a **known side
effect, not seamless**: a long-lived keep-alive connection (e.g. a
persistent admin web-UI session through the proxy) can get dropped by the
reload even though it's meant to be graceful — expect to need to log back
in to the proxied service afterward, and warn the operator before
reloading if a session is active.

No universal root cause is known for *why* a UDP logging socket like this
can stall (not necessarily a crash, not necessarily config drift). If
this recurs, worth checking your specific HAProxy version's changelog/
issue tracker for known UDP-logger-stall bugs before assuming it needs a
fresh investigation every time — behavior here can vary meaningfully
between patch versions, so verify empirically on your own build rather
than trusting documentation alone.

## Mitigation pattern: self-generated heartbeat

If the stall above recurs and self-resolves inconsistently (getting
progressively longer, or not resolving on its own), it's worth catching
sooner than "the next `gone_silent` digest flag" (which typically only
fires once, on the transition, not on sustained silence — a real gap in
volume-based digest detection, not something this mitigation fixes on its
own).

One approach: have your firewall's own watchdog/health-check script
(already running periodically to restart other daemons if they die) also
open a TLS connection to your reverse-proxy frontend without presenting a
client certificate. If the frontend requires client-cert verification, it
rejects the connection immediately — cheap, and it never reaches the
actual backend, since HAProxy terminates it at its own TLS layer — but
the rejection itself gets logged by HAProxy through the exact same
at-risk UDP socket real traffic uses:

```
haproxy[<pid>]: 192.0.2.50:<port> [<ts>] example_reverse_proxy/192.168.1.12:8006: SSL handshake failure (error:0A0000C7:SSL routines::peer did not return a certificate)
```

Considered and possibly worth ruling out first: an HAProxy option to log
every healthcheck (may or may not actually produce log lines depending on
your version — verify empirically); an external heartbeat through the
frontend's real mTLS path (works, but needs a dedicated client cert
provisioned against your CA — more setup than a source-IP-based
heartbeat needs).

**The resulting log line should be expected, permanent, and
self-identifying** — pick a `src_ip` for the heartbeat that no real
external prober will ever present (e.g. the SIEM/watchdog host's own
address, distinct from your scanner/office ranges above, all of which
should be external). Suppress it in your rules config (the TLS-probe
rule, `src_ip == "<your heartbeat source>"`) so your triage role doesn't
re-triage it every cycle; don't remove that suppression without also
disabling the heartbeat probe, or every cycle becomes a false `noise`
event.

**What this does and doesn't cover:** proves HAProxy's UDP-log path is
alive at whatever granularity your watchdog runs — a real stall now
produces a gap in this specific heartbeat shape, not just silence in
real-traffic volume, which is ambiguous on its own. It does not, by
itself, include active alerting on a *missing* heartbeat — that's a
reasonable next step to build if you adopt this pattern. Until then, "is
the heartbeat still showing up" is a manual check:

```bash
siemctl search --query "SELECT timestamp WHERE _source_type == haproxy AND src_ip == '<your heartbeat source>'" --after <window-start>
```
