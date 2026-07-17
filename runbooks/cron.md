# cron runbook

*Template: this is a starting shape based on a real deployment's runbook, with the specifics genericized. Re-derive "What normal looks like" from your own `siemctl digest`/`siemctl search` history once you have a few days of real data.*

Source: `cron` — standard Debian/Ubuntu system cron activity (not
application-level scheduled jobs). Low, very regular volume; the useful
signal here is *which* commands ran and *when* relative to the hourly
boundary, not raw count.

## What normal looks like

Two recurring, unrelated jobs typically dominate on a stock Debian/Ubuntu
box:

- **`debian-sa1` (sysstat activity accounting)** — `command -v debian-sa1
  > /dev/null && debian-sa1 1 1`, fires every 10 minutes, on the minute
  (`:05`, `:15`, `:25`, ...). Steady baseline, one event per cycle.
- **`run-parts --report /etc/cron.hourly`** — Debian/Ubuntu's standard
  hourly-cron runner, `cd / && run-parts --report /etc/cron.hourly`, fires
  once an hour at a fixed minute (whichever minute your system's crontab
  uses — check `/etc/crontab`). If your digest window is shorter than an
  hour, any window that happens to straddle that minute sees a burst of
  `run-parts`/child-job invocations on top of the steady `debian-sa1`
  baseline — a volume "spike" purely from window alignment, not a change
  in what's running.

## Known-benign: hourly-boundary volume spike

- `siemctl digest`'s volume-anomaly flag on the `cron` source, specifically
  a window that includes the hourly-cron minute, where every contributing
  event is `debian-sa1` or `run-parts --report /etc/cron.hourly` (verify
  with the first canned query below) — this is a structural artifact of
  short digest windows against an hourly job, not an anomaly in activity.
  Will recur every hour whose window includes that minute; expected, not
  worth a ticket on its own.

## Known-benign: weekly/monthly root maintenance templates

Standard Debian package cron templates worth pre-approving if your hosts
run them — both `cron_user=root`, both self-guarded (won't run outside
their own condition) and neither making network calls:

- **`zfsutils-linux` weekly scrub** — `if [ $(date +%w) -eq 0 ] && [ -x
  /usr/lib/zfs-linux/scrub ]; then /usr/lib/zfs-linux/scrub; fi`, guarded
  to Sundays only.
- **`mdadm` monthly array check** — `if [ -x /usr/share/mdadm/checkarray ]
  && [ $(date +%d) -le 7 ]; then /usr/share/mdadm/checkarray --cron --all
  --idle --quiet; fi`, guarded to the first 7 days of the month.

Both are routine storage-health maintenance, not RCE-shaped — no ticket
needed when these are the only non-standard commands seen. Adapt this
list to whatever storage/backup cron templates your own distro ships.

## Escalation criteria

- **`noise`/no ticket needed:** volume flag on `cron`, all events are
  `debian-sa1`, `run-parts --report /etc/cron.hourly`, or the
  `zfs-linux/scrub`/`mdadm/checkarray` templates above.
- **`incident` to specialist (at least medium):** any `command` value
  other than the ones above, any `cron_user` other than `root`, or a
  volume spike on `cron` that *isn't* explained by the hourly-boundary
  effect (i.e. persists in windows that don't straddle it) — first-of-kind,
  and worth real scrutiny rather than pattern-matching against this
  runbook.

## Canned queries

```bash
siemctl search --query "SELECT timestamp,cron_user,command WHERE _source_type == cron" --after <window-start>
siemctl search --query "SELECT cron_user,command,count WHERE _source_type == cron GROUP BY cron_user,command"
```

## Provenance

Drafted from a real deployment's cron baseline and re-verified against
fresh production data before writing this template — not synthetic/
assumed data, though the specifics above have been genericized for
publication. New runbooks are meant to be drafted from your own real data
and corrected by a human, not authored unsupervised by an automated role;
review this one the same way against your own environment, especially the
escalation criteria.
