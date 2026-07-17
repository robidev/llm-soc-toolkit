# pfSense gateway-monitor runbook

*Template: this is a starting shape based on a real deployment's runbook, seeded from a single confirmed occurrence. Treat it as a starting point, not exhaustive coverage — re-validate once you have more of your own data.*

Source: pfSense's internal gateway-quality/reload daemons on your
firewall host (example `10.0.50.1`) — `dpinger`, `rc.gateway_alarm`,
`check_reload_status`, `php-fpm`. Distinct from `filterlog` (see
`filterlog.md`), which is the firewall pass/block log itself; these are
pfSense's own housekeeping around WAN link quality.

## What normal looks like: WAN-gateway-alarm reload cascade

`dpinger` continuously monitors the WAN gateway (e.g. `WANGW`, your
upstream router's address — could be your ISP's own gateway or, in a
nested topology, an upstream router you don't directly control)
latency/packet loss and alternates `Alarm`/`Clear` states through
`rc.gateway_alarm` when thresholds are crossed, e.g.:

```
Alarm latency 2008us stddev 295us loss 21%
```

This is pfSense's **built-in** gateway-quality monitor — not
attacker-controlled, not a config change made by a person. An `Alarm`
automatically triggers pfSense's standard self-healing reload chain,
visible in `check_reload_status`/`php-fpm`:

- "Restarting IPsec tunnels"
- "Restarting OpenVPN tunnels/interfaces"
- "Reloading filter"
- "updating dyndns WANGW"
- `php-fpm`'s `/rc.openvpn: ... tunnel endpoints may have changed IP
  addresses. Reloading endpoints that may use WANGW.`

**Correlated `filterlog` effect:** the reload cascade above plus routine
outbound DNS(53)/HTTPS(443)/NTP(123) traffic from your own infrastructure
can explain a `filterlog` volume bump in the same window — check it's
still well within `filterlog.md`'s documented low-volume baseline before
treating it as a separate finding.

## Escalation criteria

- **Benign:** an `Alarm`/`Clear` pair from `dpinger` correlated with a
  reload cascade in `check_reload_status`/`php-fpm` and nothing else
  unexpected — WAN link-quality blips like this are expected to recur.
- **`incident` to specialist:** a sustained `Alarm` with no matching
  `Clear` (extended WAN outage, not a blip); a reload cascade that
  **isn't** preceded by a `dpinger` alarm (would suggest an actual
  unauthorized config change triggering reloads, not the self-healing
  path); or any reload activity that correlates with an unexpected
  firewall-rule change rather than just IPsec/OpenVPN/filter/dyndns
  refresh.

## Canned queries

```bash
siemctl search --query "SELECT timestamp,hostname,message WHERE _source_type == dpinger" --after <window-start>
siemctl search --query "SELECT timestamp,hostname,message WHERE _source_type == rc.gateway_alarm" --after <window-start>
siemctl search --query "SELECT timestamp,hostname,message WHERE _source_type == check_reload_status OR _source_type == php-fpm" --after <window-start>
siemctl search --query "SELECT interface,dst_port,count WHERE _source_type == filterlog AND action == ALLOW GROUP BY interface,dst_port" --window <window>   # confirm the correlated filterlog bump is routine composition
```

## Provenance

Seed this section from your own first confirmed occurrence — there's
often no prior ticket precedent the first time a `gateway_alarm`/
`dpinger`/`WANGW` event shows up. Re-validate against a real recurrence;
WAN link-quality issues like this are likely to repeat.
