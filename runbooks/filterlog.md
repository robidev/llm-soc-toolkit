# filterlog runbook

*Template: this is a starting shape based on a real deployment's runbook, with the specifics genericized (RFC1918/RFC5737 example addressing throughout). Re-derive "What normal looks like" from your own `siemctl digest`/`siemctl search` history once you have a few days of real data — filterlog volume and composition depend heavily on your own firewall's rule set and logging preferences.*

Source: `filterlog` (pfSense firewall block/allow log, running on your
firewall host — example `10.0.50.1`). Feeds the digest's network/coverage
sections and the `firewall-port-scan` correlation rule.

## Interface labels (pfSense physical/VLAN names → what they are)

Replace this table with your own subnets and VLAN numbering — the shape
(a WAN interface, an unlogged default-allow LAN, and one VLAN per
security zone) is the useful part, not these specific numbers:

| interface | zone | subnet | notes |
|---|---|---|---|
| `wan` | WAN | 192.168.1.0/24 | Upstream/ISP-facing interface — replace with your own WAN addressing (may be a nested private range if you sit behind another router, or a public IP) |
| `lan` | LAN | 10.0.0.0/24 | Default allow-to-any, not logged (by design — highest-volume path, deliberately excluded) |
| `vlan10` | VLAN10 | 10.0.10.0/24 | e.g. a hypervisor/management network |
| `vlan20` | VLAN20 | 10.0.20.0/24 | e.g. general internal services |
| `vlan30` | VLAN30 | 10.0.30.0/24 | e.g. IoT/untrusted devices |
| `vlan50` | VLAN50 | 10.0.50.0/24 | SIEM/management zone — your-siem-host itself (e.g. `10.0.50.11`) lives here |
| `vlan60` | VLAN60 | 10.0.60.0/24 | DMZ zone — e.g. an internet-facing or canary host (e.g. `10.0.60.10`) |

## Tuning filterlog volume: default-pass/default-block logging preferences

If `filterlog` volume looks surprisingly high (tens of thousands of
events/day, dominated by traffic that never matches a rule you actually
wrote), check whether pfSense's *reserved* default-pass/default-block
rules are logging. These aren't your `USER_RULE`s — they're
non-user-editable rule classes pfSense applies automatically, and each is
controlled by a single checkbox under `System > Advanced > Firewall &
NAT`:

1. **`nologdefaultpass`** — silences the reserved catch-all that logs
   *every* routed/NAT'd packet leaving via WAN that no `USER_RULE` already
   claimed, plus loopback, DHCP client/server/relay, IPsec housekeeping,
   and the LAN-only "anti-lockout rule" traffic. On a box with any
   moderately chatty internal service (NFS, backup jobs, etc.), this can
   dwarf everything else. Before assuming a specific named rule is the
   culprit, check the log line's rule-tracker field (`ridentifier`) — it's
   easy to misattribute high volume to `wan to any` or a similar
   user-visible rule when the real source is this reserved default.
2. **`nologdefaultblock`** — silences the reserved "block all" rule for
   any protocol family you don't use (e.g. IPv6, if disabled network-wide)
   plus general default-deny background noise (link-local multicast
   beacons from unrelated devices on your upstream network, etc.).
   **Trade-off to weigh explicitly:** this same preference typically also
   silences your intrusion-prevention daemon's (e.g. `sshguard`) blocks
   and GUI-lockout blocks at the firewall-log level. If SSH/admin access
   isn't reachable from the internet anyway, and you don't use the
   protocol family being blocked, disabling this is often an acceptable
   trade — but confirm your brute-force detection has a *separate* signal
   (e.g. the daemon's own log, forwarded as its own `_source_type`) before
   relying on that trade-off. Don't read filterlog's silence on
   brute-force blocks as "no brute-force attempts happened" if you've made
   this trade.

Disabling both is usually enough to drop filterlog to a "few hundred
events/hour, essentially all named `USER_RULE`s" baseline — an order of
magnitude or more lower than the reserved-rule-inclusive baseline, without
losing signal, since every explicitly-configured pass/block rule
(reverse-proxy access, VPN, your trailing `block and log any` rule on
each interface) is unaffected.

Other common volume drivers worth checking before assuming the reserved
defaults are the whole story: a reverse-proxy healthcheck interval set
too aggressively against a monitored backend (a few-second interval can
itself be a large share of logged/routed traffic — widening it is cheap
and safe), and `log` enabled on a high-volume pass rule (e.g. a broad
`wan to any`) that doesn't actually need per-connection logging.

**If `filterlog` volume ever climbs back toward a pre-fix level**, check
whether `nologdefaultpass`/`nologdefaultblock` got silently re-enabled in
`config.xml` before assuming a real traffic change — both are one GUI
checkbox each.

One small residual worth knowing about: IGMP or similar link-local
protocol traffic from an upstream router can occasionally log with
`reason=ip-option` rather than a rule match — that's pf's built-in
IP-options sanity check, a mechanism separate from rule-level logging
entirely (it bypasses a `nolog`-tagged block rule). Low-volume, cosmetic,
not worth chasing.

## What normal looks like (after tuning the defaults above)

- Near-silent: on the order of a few hundred events/hour, not thousands,
  once the default-pass/default-block preferences above are tuned.
- Composition is almost entirely PASS traffic from your own
  infrastructure hosts' outbound DNS (53), NTP (123), and HTTPS (443)
  chatter, matching named `USER_RULE`s — not reserved defaults.
- Occasional cosmetic `ip-option` block from an upstream router (see
  above).
- Zero real port scans/unicast block bursts is the expected steady state
  for a small deployment; the correlation rule (`firewall-port-scan` /
  similar) should otherwise only fire against your test fixture (see
  Canned queries).

## Known-benign: IPv4/IPv6 multicast blocks

If you haven't disabled `nologdefaultblock` (or if some multicast/
broadcast traffic still gets logged for other reasons), suppress it at
the alert layer rather than chasing each occurrence as an incident:

```toml
[[suppress]]
rule_id = "1009-firewall-port-scan"
condition = 'cidr_match(dst_ip, "224.0.0.0/4") OR dst_ip == "255.255.255.255"'
note = "IPv4 multicast/broadcast background noise — runbooks/filterlog.md"
expires = "<review date>"

[[suppress]]
rule_id = "1009-firewall-port-scan"
condition = 'dst_ip == "ff02::2" OR dst_ip == "ff02::c" OR dst_ip == "ff02::16" OR dst_ip == "ff02::fb"'
note = "IPv6 link-local multicast background noise — runbooks/filterlog.md"
expires = "<review date>"
```

## Escalation criteria

- **Benign:** routine outbound DNS/NTP/HTTPS chatter from your own
  infrastructure. The occasional cosmetic `ip-option` block from an
  upstream router. None of this is worth a ticket on its own.
- **`missing_logs` to user:** filterlog absent from coverage — a real gap,
  file it. Don't mistake a newly-lowered baseline (after tuning defaults
  per above) for `gone_silent` — check whether volume is low-but-present
  vs. actually zero.
- **`incident` to specialist (≥medium):** anything landing on a `block and
  log any` `USER_RULE` on any interface. A block burst against a
  *unicast* destination, especially on the WAN-facing interface or
  multi-port from one source. Any `ALLOW` to an internal host on a port
  outside your environment runbook's known-normal list.
- **Brute-force / IPS coverage:** if you've traded off `nologdefaultblock`
  (see above), filterlog will **not** show your IPS's blocks — check that
  daemon's own source type for that signal instead.

## Canned queries

```bash
siemctl search --query "SELECT src_ip,dst_ip,count WHERE _source_type == filterlog AND action == BLOCK GROUP BY src_ip,dst_ip LIMIT 20"
siemctl search --query "SELECT timestamp,src_ip,dst_ip,dst_port WHERE _source_type == filterlog AND interface == wan AND action == ALLOW LIMIT 20"
siemctl search --query "SELECT interface,dst_port,count WHERE _source_type == filterlog AND action == ALLOW GROUP BY interface,dst_port LIMIT 20"   # volume-by-source sanity check
siemctl digest --window 1h   # confirm filterlog is even reporting first
siemctl search --query "SELECT timestamp,raw WHERE _source_type == sshguard LIMIT 20" --window 24h   # brute-force signal, if filterlog itself doesn't show IPS blocks
```
