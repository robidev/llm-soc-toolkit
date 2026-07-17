# networkd-dispatcher runbook

*Template: this is a starting shape based on a real deployment's runbook, seeded from a single confirmed occurrence. Treat it as a starting point, not exhaustive coverage — re-validate once you have more of your own data.*

Source: `networkd-dispatcher` — reacts to network interface state
changes (dispatches scripts on link up/down/enumeration events).

## What normal looks like (example case)

**`WARNING:Unknown index N seen, reloading interface list` immediately
after a host boot, while the network stack is still enumerating
interfaces for the first time.** Example, on a canary host:

```
{"timestamp":"<ts>","hostname":"canary2","message":"WARNING:Unknown index 3 seen, reloading interface list"}
{"timestamp":"<ts>","hostname":"canary2","message":"WARNING:Unknown index 4 seen, reloading interface list"}
```

If both events fire the exact same second as that host's confirmed
genuine reboot (see `systemd.md`'s boot-sequence guidance and
`environment.md`'s canary-host section — a reboot should be independently
investigated and operator-confirmed as expected/planned before treating
this pattern as benign), a `networkd-dispatcher` "Unknown index N"
warning at that exact moment is the dispatcher reacting to interfaces it
hasn't seen indexed yet — an expected transient artifact of interface
enumeration during boot, not a fault. Check a wider window (e.g. 7 days)
for repeats of the same message shape from the same host before treating
this as an established pattern rather than a one-off.

## Escalation criteria

- **Benign:** `WARNING:Unknown index N seen, reloading interface list`,
  correlating with a `systemd` boot sequence on the same host within the
  same second-to-minute, especially when that boot is itself already
  documented as benign.
- **`incident` to specialist:** a `networkd-dispatcher` warning with no
  correlating boot event nearby (interface churn on an already-running
  host is a different, unexplained signal); repeated/sustained
  occurrences past the initial boot enumeration; any message shape other
  than "Unknown index N seen, reloading interface list" (treat as
  first-of-kind until you've built a baseline); or any occurrence on a
  canary host specifically — per `environment.md`'s canary-host section,
  findings on canary hosts must never be auto-closed as benign regardless
  of investigator confidence, even once a pattern is well-established
  elsewhere.

## Canned queries

```bash
siemctl search --query "SELECT timestamp,hostname,message WHERE _source_type == \"networkd-dispatcher\"" --after <window-start>
siemctl search --query "SELECT timestamp,hostname,unit,message WHERE _source_type == \"systemd\" AND hostname == \"<host>\"" --after <event hour>   # correlate with the triggering boot
```

## Provenance

Seed this section from your own first-of-kind occurrence, correlated
with an already-investigated and operator-confirmed benign reboot (see
`systemd.md`). Re-validate once more `networkd-dispatcher`-sourced events
accumulate; treat the escalation criteria above as a reasonable first
cut, not confirmed against a real incident until you've exercised it.
