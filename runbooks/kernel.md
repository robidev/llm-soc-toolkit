# kernel runbook

*Template: this is a starting shape based on a real deployment's runbook. The example cases below are illustrative of the general pattern (AppArmor confinement being stricter than an app expects) — seed this file from your own confirmed occurrences rather than trusting these verbatim.*

Source: `kernel` — kernel-level audit lines forwarded from syslog
(AppArmor confinement decisions, and anything else the kernel audit
subsystem logs). Treat a freshly-seeded version of this runbook as a
starting point, not exhaustive coverage — AppArmor denial shapes vary a
lot by distro, installed snaps/packages, and desktop vs. server role.

## What normal looks like (example cases)

**AppArmor `DENIED` lines for a snap-confined app reading a harmless
`/proc/sys/*` value, correlated with that snap's own service start.**
Example shape, on a desktop host:

```
audit: type=1400 audit(...): apparmor="DENIED" operation="open" class="file"
profile="snap.firmware-updater.firmware-notifier" name="/proc/sys/vm/max_map_count"
pid=... comm="firmware-notifi" requested_mask="r" denied_mask="r" fsuid=1000 ouid=0
```

If this fires in the same digest window as that snap's own service
starting (see `systemd.md`'s guidance on routine desktop housekeeping
units), an AppArmor profile blocking a *read* of a non-sensitive
`/proc/sys/*` value — not a write, not credential material — is a normal
side effect of snap confinement being stricter than the app expects, not
a security event.

**AppArmor `DENIED` line for a system daemon's own capability check,
firing during that daemon's own scheduled restart.** Example shape (e.g.
a print daemon restarting as part of a midnight housekeeping cycle):

```
audit: type=1400 audit(...): apparmor="DENIED" operation="capable"
class="cap" profile="/usr/sbin/cupsd" pid=... comm="cupsd" capability=12  capname="net_admin"
```

If this fires within the same restart cycle systemd already documents as
routine logrotate/housekeeping (see `systemd.md`), with no repetition
outside that window, no correlated alert, and the service starting
successfully despite the denial — this is the same "confinement stricter
than app expects" shape as the snap case above, just a capability check
(`class="cap"`) instead of a file read (`class="file"`).

Both of the above are worth carving out as *explicit, narrow* exceptions
to a default "any AppArmor denial is worth a look" posture — not a
blanket "AppArmor denials are fine" rule. Add your own confirmed-benign
cases here the same way, one specific `profile`/`class`/target shape at a
time, each correlated with an independently-understood trigger event.

## Escalation criteria

- **Benign:** an AppArmor `DENIED` matching one of the specific,
  correlated shapes documented above (or your own equivalent, once
  you've confirmed it the same way) — narrow profile/class/target match,
  correlated with an already-understood trigger event, no repetition
  outside that trigger.
- **`incident` to specialist:** any AppArmor `DENIED` targeting
  credentials, `/etc/shadow`, key material, or a network/exec permission;
  any `class` other than `file`/`cap`, or a `cap`/`file` denial outside
  your specific confirmed-benign shapes; a profile name not matching a
  known snap/service on your systems; high volume or a sustained pattern
  from a profile not seen before; or any kernel-sourced event that isn't
  an AppArmor line at all (treat as first-of-kind until you've built up
  your own baseline).

## Canned queries

```bash
siemctl search --query "SELECT timestamp,hostname,message WHERE _source_type == kernel" --after <window-start>
siemctl search --query "SELECT timestamp,hostname,message WHERE _source_type == systemd AND raw_contains('<snap-or-service-name>')" --after <window-start>   # correlate with the triggering service/snap
```

## Provenance

New runbooks like this one are meant to be seeded from a real confirmed
occurrence (an analyst/investigator ticket) and then re-validated once
more events of the same source accumulate — not authored unsupervised
from imagined patterns. The escalation criteria above are a reasonable
first cut based on standard AppArmor semantics; treat them as a draft to
correct against your own environment's real data, not a finished
baseline.
