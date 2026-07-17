# openvpn runbook — placeholder, no real data yet

*Template: this is a placeholder shape based on a real deployment's runbook. Fill it in from your own actual `openvpn` events once you have some — don't draft escalation criteria from imagination.*

If your SIEM's normalization config already has a dedicated extraction
rule for `openvpn` and your sources config defines the `openvpn` source's
index fields, but **zero `openvpn` events have ever been indexed**, it's
worth confirming the source is actually configured and forwarding before
assuming it's broken:

- Check directly on the VPN endpoint (e.g. via firewall shell access)
  that an OpenVPN server is actually configured and enabled, not just
  present in config but disabled.
- Check that your syslog forwarding catch-all covers `openvpn`-tagged
  messages the same way it covers everything else.
- If both check out, the most likely explanation for sustained silence is
  simply that nobody has connected to the VPN recently enough to generate
  a log line — OpenVPN typically only logs on connect/disconnect/rekey,
  not ongoing traffic, so this can legitimately stay sparse for a
  rarely-used homelab VPN. Not necessarily worth chasing further; don't
  be surprised if this stays empty for a while on a low-traffic
  deployment.

**Do not draft escalation criteria or known-benign patterns from
imagination here** — once real `openvpn` events exist, redo this runbook
from actual data the same way the other source runbooks were done,
rather than guessing at what a VPN log pattern "should" look like.

## Canned queries (to check whether this is still empty)

```bash
siemctl search --query "SELECT timestamp,username,src_ip WHERE _source_type == openvpn LIMIT 5"
siemctl stats --source openvpn --last 7d
```
