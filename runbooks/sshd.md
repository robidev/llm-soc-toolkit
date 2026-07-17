# sshd runbook

*Template: this is a starting shape based on a real deployment's runbook, with the specifics genericized. Re-derive "What normal looks like" from your own `siemctl digest`/`siemctl search` history once you have a few days of real data.*

Source: `sshd`. On a small homelab-scale deployment, real activity is
often concentrated on a handful of admin-facing hosts (e.g. hypervisor
nodes); other hosts (a jump host, canary hosts) may forward `sshd` too
but log no real auth events for a while — that's expected on a low-traffic
deployment, not evidence of a gap.

## What normal looks like

Real volume is often very low (tens of events/72h across a small cluster)
on a small homelab — not a shell server, so any spike is meaningful on
its own. A plausible benign pattern: successful `root` logins from one
admin/management host into each cluster node in quick succession,
matching a known config-push automation run — not lateral movement.
**Zero real auth failures** is a reasonable expectation for a
low-traffic deployment — if every `ssh-brute-force`/`suspicious-ssh`
alert on record is against your pre-production test fixture (e.g.
`hostname=victim`, `203.0.113.0/24` — an RFC5737 documentation range used
by your detection tests), don't treat that historical alert volume as a
real baseline rate; the real rate may genuinely be zero until it isn't.

## Known-benign pattern

- Root login from one admin host to another, clustered in a short window
  — config-push automation, not lateral movement. No suppression needed
  at this volume; re-verify if volume grows enough that this becomes a
  daily pattern rather than an occasional one.

## Escalation criteria

- **`incident` to specialist (≥medium):** any real auth failure (first
  occurrence is inherently notable on a low-volume deployment), a login
  from outside your known internal address space (e.g. `10.0.0.0/16`),
  or a successful login as anything but your known admin accounts.
- **High/critical, direct notify:** a real `suspicious-ssh` or
  `ssh-brute-force` match against a genuine (non-test) target — would be
  a first occurrence on a quiet deployment, don't wait for the next
  scheduled triage cycle.

## Canned queries

```bash
siemctl search --query "SELECT timestamp,src_ip,username,hostname WHERE _source_type == sshd AND auth_action == Accepted LIMIT 20"
siemctl search --query "SELECT src_ip,username,count WHERE _source_type == sshd AND auth_action == Failed GROUP BY src_ip,username"
siemctl stats --source sshd --interval 6h --last 72h
```
