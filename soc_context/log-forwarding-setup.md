# Log forwarding setup (template)

**This is genuinely per-deployment** — rewrite it for whatever
infrastructure you actually run. This template gives a generic
rsyslog recipe plus one illustrative device-specific example (a
pfSense-style firewall, since that's a common homelab gateway); swap
the example for your own gear. The underlying generic rsyslog/journald
recipe lives in `headless-siem/docs/forwarding-to-normalized.md` — this
doc is the device-by-device instructions layered on top of that.

## Target

Wherever `headless-siem-normalized` is listening — check
`headless-siem/config/normalized.toml` or however you've configured it
(the shipped default is UDP, and the exact port is your own choice; pick
one and use it consistently below). Example placeholder used throughout
this template: `10.0.20.11:5514`.

## Generic Linux host (rsyslog)

On any Debian/Ubuntu/RHEL-family host with rsyslog:

```bash
# /etc/rsyslog.d/90-forward-to-siem.conf
*.* @10.0.20.11:5514;RSYSLOG_SyslogProtocol23Format      # UDP
# *.* @@10.0.20.11:5514;RSYSLOG_SyslogProtocol23Format   # TCP (double-@)
```

```bash
systemctl restart rsyslog
```

**Use `RSYSLOG_SyslogProtocol23Format`, not the plain forwarding
default.** Without it, rsyslog forwards in RFC3164 ("BSD syslog")
format, which has no timezone in the timestamp — `normalized` then has
to assume UTC, which is wrong for any sender whose local clock isn't
UTC. That silently buckets events into the wrong hour.
`RSYSLOG_SyslogProtocol23Format` is a template built into rsyslog itself
(no need to define it) that emits RFC5424 with a full timestamp and
explicit UTC offset.

## Example: pfSense-style firewall (GUI-configured, no rsyslog.conf)

Some firewalls/gateways (pfSense among them) don't use a hand-edited
rsyslog.conf — they're configured via a web GUI that generates syslog
config internally. Adapt the specifics to whatever your own gateway
actually offers:

1. Enable remote logging in the gateway's logging settings.
2. Point it at your SIEM host/port (the target above). UDP is the
   default and fine for a homelab; TCP is available on some platforms if
   you want delivery confirmation, at the cost of the sender blocking
   briefly if the receiver is unreachable.
3. Pick what to forward — at minimum firewall/filter events (feeds the
   SIEM's port-scan correlation and volume digest), plus system events
   and VPN events if applicable.
4. Verify on the gateway's own side that remote logging shows enabled
   with no send errors, and confirm your firewall rules actually allow
   the gateway to reach the SIEM host on the chosen port/protocol — a
   locked-down management segment often needs an explicit allow rule for
   this.

## After forwarding is set up

Verify real traffic is actually landing, not just that the digest
mentions the source (a source can appear via test-injected data without
real traffic ever arriving):

```bash
cd /path/to/headless-siem
find data/raw/$(date -u +%Y/%m)/* -name '*.jsonl' | xargs -I{} python3 -c "
import json
with open('{}') as f:
    for line in f:
        try:
            d = json.loads(line)
        except Exception:
            continue
        h = d.get('hostname') or d.get('source_addr')
        if h: print(h)
" 2>/dev/null | sort | uniq -c | sort -rn

siemctl digest --data-dir data --window 1h
```

Expect each forwarding host's real address to show up, with non-zero,
non-test-injection counts for its actual log sources in the digest's
coverage section.
