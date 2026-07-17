# sudo runbook

*Template: this is a starting shape based on a real deployment's runbook, with the specifics genericized. Re-derive "What normal looks like" from your own `siemctl digest`/`siemctl search` history once you have a few days of real data.*

Source: `sudo` — reflects operator/admin command execution, not
application behavior. On a small homelab-scale deployment, real activity
is often concentrated on a handful of admin-facing hosts (e.g. hypervisor
nodes).

## What normal looks like

On a low-traffic deployment, expect extremely low real volume (a handful
of events in the first days of production) — a plausible benign pattern
is a known admin account escalating to root while performing a specific,
identifiable maintenance task (e.g. editing a config file, restarting a
service, rebooting). At this volume, there's no "typical daily count"
yet — any sudo activity at all is worth a glance, and a sudden cluster of
many events in a short window is a more useful signal than raw count.

## Known-benign pattern

- A known admin account escalating to root and running standard admin
  commands (editors, service managers, reboot, etc.) on a known
  admin-facing host during a known maintenance window (check your
  ticketing history or ask the operator if unclear — don't assume benign
  just because the command looks ordinary).

## Escalation criteria

- **`incident` to specialist (at least medium):** `target_user` other
  than `root`, `username` other than a known admin account, or a command
  matching your privilege-escalation correlation rule (root shell or
  sensitive binary — e.g. an interactive shell spawned via sudo rather
  than a specific command).
- **High/critical, direct notify:** sudo activity with no corresponding
  known maintenance action and originating from a source other than your
  known internal admin address space — treat as first-of-kind on a quiet
  deployment.
- Cross-reference the `sshd` runbook — sudo activity is far more
  meaningful in the context of *how* the session that ran it authenticated.

## Canned queries

```bash
siemctl search --query "SELECT timestamp,username,target_user,command WHERE _source_type == sudo LIMIT 20"
siemctl search --query "SELECT username,target_user,count WHERE _source_type == sudo GROUP BY username,target_user"
```
