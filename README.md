# llm-soc-toolkit

![Alt text](soc.png?raw=true "Moody cartoon picture about the llm soc")

A toolkit for running an LLM-driven SOC on top of
[`headless-siem`](https://github.com/robidev/headless-siem), a sibling
SIEM project. Four Claude roles, each with its own scoped sandbox and
Unix account, poll the SIEM on a schedule, triage findings against
runbooks, and hand off work via a file-based ticketing system — a human
operator is pulled in only when a role can't resolve something itself.

This repo is a sanitized, generic extraction of a real, working homelab
deployment — the scripts, prompts, permission model, and sandboxing are
all the actual mechanism, not a design sketch. What's deployment-specific
(your network topology, your runbooks' real traffic baselines, your ntfy
channel) ships as empty templates for you to fill in — see the
[deployment guide](documentation/deployment-guide.md).

## Architecture

```
                 headless-siem (data/, siemctl, alert-watch)
                              │  digest / alerts / search
                              ▼
        ┌───────────────────────────────────────────────┐
        │                  4 roles                        │
        │  analyst    — short interval, triages the digest,│
        │               opens tickets for anything odd     │
        │  specialist — hourly, drains tickets assigned     │
        │               to it, investigates against         │
        │               runbooks, closes or escalates       │
        │  tuner-dev  — every few hours, the only role with  │
        │               write access to headless-siem; fixes  │
        │               noise/parsing/tuning tickets via a      │
        │               branch + scripts/tuner-review            │
        │  soclead    — nightly + weekly, reports on the SOC's  │
        │               own output over time (no investigation) │
        └───────────────────────────────────────────────┘
                              │  ticketing-system/<role>/*.md
                              ▼
        human operator (scripts/soc-ticket, scripts/soc-run-role, ...)
```

Each role runs sandboxed (`soc-run-role`) under its own `soc-<role>` Unix
account, with a per-role permission manifest enforced by a PreToolUse hook
— out-of-manifest calls are logged (`permission-audit/`) and, for
repeating patterns, escalated to the operator as a ticket
(`scripts/soc-escalate`). A repo-root `PAUSED` file is the kill switch:
its presence silently skips every role run and notification.

## Design Principles

- **Cheap by default, escalate by exception.** The analyst's first pass is
  a low-effort, cheap-model call; only a finding that needs it triggers a
  second, more capable call. Most runs should end in `result=clear`.
- **Tickets, not chat.** All handoff between roles (and to the human) is a
  markdown file moved atomically between owned folders — no shared state,
  no locks, one owner at a time.
- **Sandboxed by manifest, not by trust.** Every role's tool access is an
  explicit allow/deny list; `tuner-dev` is the only role that can write to
  the SIEM, and only inside its own worktree.
- **A human is a ticket type, not a fallback.** `missing_logs` and
  `permission_gap` tickets route to `user` because only a human can fix
  what they describe — not because a role gave up.
- **Deterministic safety nets stay deterministic.** Rate limits, the
  `PAUSED` kill switch, and pipeline-restart cooldowns are plain scripts,
  not something an LLM call could be talked out of.

## Components

| Role | Cadence | Job |
|---|---|---|
| `analyst` | short interval (e.g. every 10-60 min) | Reads the SIEM digest, classifies anomalies, opens tickets |
| `specialist` | hourly | Investigates tickets assigned to it against runbooks; closes or hands off |
| `tuner-dev` | every few hours | Fixes SIEM-side noise/tuning/parsing issues via a branch; only role with SIEM write access |
| `soclead` | nightly / weekly | Reports on SOC activity over time; no per-ticket investigation |

Plus the operator scripts in `scripts/` (ticketing, running a role by
hand, permission/deploy-drift checks, notifications) — see
`.claude/skills/soc-tools/SKILL.md` for the full command reference.

## Quick Start

**Read the [deployment guide](documentation/deployment-guide.md) first**
— it's the actual step-by-step path from two fresh clones to a live,
cron-driven SOC, including the parts that are genuinely per-deployment
(your network docs, your runbooks, your notification channel). Once
deployed:

```bash
# Check what's open across every role
sudo scripts/soc-ticket list

# Run a role out-of-cycle and watch it live
sudo scripts/soc-run-role --watch analyst

# Replay a past run
sudo scripts/soc-transcript analyst --list

# Read and close a ticket by hand
sudo scripts/soc-ticket show ticketing-system/specialist/some-ticket.md
sudo scripts/soc-ticket close ticketing-system/specialist/some-ticket.md "resolved: ..."
```

## What's included

- **All 4 roles** — prompts, manifests, and sandboxing for
  `analyst`/`specialist`/`tuner-dev`/`soclead`, designed to run under
  `enforce` mode (full allow-list + auto-deny) after an `audit`-mode
  soak period to shake out manifest gaps against your own environment.
- **Ticketing system** — file-based, ownership-by-folder, atomic
  reassignment; 11 ticket types with a defined routing table
  (`ticketing-system/system.md`).
- **Permission enforcement** — per-role manifests promoted to native
  Claude Code settings (`soc-build-settings`), backed by a PreToolUse hook
  as defense-in-depth; drift/denial patterns auto-escalate to a ticket.
- **Housekeeping automation** — permission healing, context-balloon
  detection, and escalation all run from `soc-run-role`'s post-run gate;
  session-transcript cleanup runs from a weekly systemd timer.
- **Runbook templates** — per-source triage guidance (filterlog,
  haproxy, sshd, cron, systemd, ...) plus an environment cheat-sheet,
  shipped as templates with safe example data — rewrite them from your
  own traffic baseline once you have a few days of real history.
- **Operator skill** (`soc-tools`) for hands-on triage from Claude Code
  itself.

## What you need to bring

- Your own `headless-siem` deployment, actually receiving logs.
- Your own network documentation (`soc_context/`) and runbooks, written
  from your own traffic — the shipped versions are templates, not data.
- Your own ntfy topic (or other notification channel) — never deploy the
  placeholder in `config/notify.conf` unchanged.
- A dedicated credential for unattended cron runs is strongly
  recommended over sharing your own interactive session's token — see
  `soc-structure/runner-and-permissions.md` §9.

See the deployment guide's "Known limitations" section for the current
portability gaps (hardcoded install path/username, no relocate-in-place
tooling) before you deviate from the defaults.
