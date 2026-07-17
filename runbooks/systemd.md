# systemd runbook

*Template: this is a starting shape based on a real deployment's runbook, with the specifics genericized. Re-derive "What normal looks like" from your own `siemctl digest`/`siemctl search` history once you have a few days of real data.*

Source: `systemd` — service lifecycle events (`Starting`/`Started`/
`Stopping`/`Stopped`/`Finished`/`Deactivated successfully`) across every
host that forwards logs — desktop hosts, hypervisor/cluster nodes, and
any other hosts you run (including canary hosts). Indexed fields are
often only `event_type` (`unit_starting`/`unit_started`/`unit_stopping`/
`unit_stopped`, frequently `null` on the plain `Finished .../Deactivated
successfully.` follow-up lines) and `unit`; the human-readable detail is
usually in `message`, which isn't indexed — project it explicitly
(`SELECT ... message ...`) or use `raw_contains(...)`.

## What normal looks like

Once you have a few days of real data, volume is often almost entirely
routine package/service maintenance — clean start→finish pairs, no
failures:

- **Firmware/metadata refresh services** — several times a day on a
  desktop host, typically `Starting` → `Deactivated successfully` →
  `Finished` within under a second.
- **`anacron.service`** (or similar periodic job runner) — desktop host,
  same clean-cycle shape, roughly hourly.
- **`apt-daily.service` / `apt-daily-upgrade.service`** (or your distro's
  equivalent) — daily package download/upgrade housekeeping, all hosts,
  `Starting` → a package-management helper service starts alongside it →
  both deactivate cleanly a few seconds later. Often logs a `Consumed
  N.NNNs CPU time...` accounting line as its last event — normal, not a
  performance signal.
- **`systemd-tmpfiles-clean.service`** — scheduled tmp-directory cleanup,
  all hosts, clean cycle.
- Various desktop housekeeping units (update notifiers, man-db indexing,
  filesystem trim, message-of-the-day refresh) — same shape, various
  cadences.
- **Cluster-node daily-update/firewall-logger/proxy-reload cycles** — a
  hypervisor cluster's own daily housekeeping and firewall-logger
  restarts.

None of these are core boot/init units — no `systemd-journald`,
`systemd-udevd`, `NetworkManager`, and no kernel boot messages accompany
them. A burst of several of the units above starting/stopping within the
same minute is expected background noise, not a host restart.

## Known-benign: midnight logrotate/housekeeping cycle (daily, all hosts)

A common pattern worth confirming on your own hosts: at each host's local
midnight, a database-backup or logrotate service fires (Debian's standard
daily log-rotation cron path, or your distro's equivalent). Postrotate
hooks can cause a predictable secondary burst — for example:

- **A desktop host's print stack cycling** — a CUPS-related service
  stopping and restarting within the same minute as logrotate, alongside
  the logrotate/backup services themselves.
- **On cluster nodes:** a firewall-logger service stopping and
  restarting, and the syslog daemon logging a "signal SIGHUP to main
  process" message on client request — the syslog restart can also be
  the likely trigger for a `new_sources`-flapping burst on other
  low-volume sources in the same window (a syslog daemon re-opening
  inputs can momentarily surface low-volume sources as "new" in a digest
  tool's coverage check).
- **Also on cluster nodes:** a web-proxy/console-proxy service showing
  `Reloading.../Reloaded...` pairs in the same window — part of the same
  daily cycle, not a separate event.

A `boot_storms`-style flag (N units restarting within one minute) firing
on this pattern is the detector working as designed, not a bug — the
label is just misleading for this specific shape: check the unit list
before treating a `boot_storms` hit as a real reboot. A real reboot would
show core boot/init units (`systemd-journald`, `systemd-udevd`, kernel
boot lines) alongside or instead of the housekeeping units above.

## Escalation criteria

- **`noise`/no ticket needed:** any of the routine units above cycling
  cleanly (every `Starting`/`Stopping` has a matching `Deactivated
  successfully`/`Finished`/`Started`/`Stopped`), including the midnight
  logrotate burst.
- **`incident` to specialist (at least medium):** a unit that fails to
  reach its terminal state (`Starting`/`Stopping` with no matching
  completion line within a reasonable window), any `failed`/`Failed
  with result` message, a boot-storm hit that *does* include core
  boot/init units (`systemd-journald`, `systemd-udevd`,
  `NetworkManager`, kernel boot messages), or any unit name not seen in
  this runbook's baseline — first-of-kind, worth real scrutiny.

## Canned queries

```bash
siemctl search --query "SELECT timestamp,hostname,unit,message WHERE _source_type == systemd" --after <window-start>
siemctl search --query "SELECT unit,count WHERE _source_type == systemd GROUP BY unit" --after <window-start>
siemctl digest --window <window> --format json   # check .notable.boot_storms unit list before treating as a reboot
```

## Provenance

Drafted from live production data plus a midnight-logrotate section
root-caused from an investigation ticket, re-confirmed against fresh data
rather than taken on the original ticket's word alone. Draft your own
version interactively with a human reviewer rather than authoring
escalation criteria unsupervised — review them in particular until
you've exercised this runbook against a real failure/incident case.
