---
name: soc-tools
description: Use when the operator (running as `user`, not a sandboxed SOC role) wants to triage/maintain the SOC deployment by hand -- reading/closing tickets, running a role manually, restarting the SIEM pipeline, deploying a fix, or checking permission/deploy drift. Not auto-loaded for the four SOC roles (Skill tool is denied in their manifests) -- read directly, or via this repo's CLAUDE.md pointer.
---

# soc-tools

## Purpose

A command reference for operating this SOC deployment by hand -- the thing you reach
for from a phone/remote session (or locally) when an ntfy alert or your own check-in
means you need to look at tickets, run a role out-of-cycle, or fix something in the
pipeline. This is an index, not a replacement for the fuller docs it links to.

**Always run these from `/home/user/projects/llm-soc-toolkit`** -- most need `sudo`,
and several resolve paths relative to cwd (a bare `soc-ticket: command not found`
usually just means the wrong directory).

## Tickets -- `soc-ticket`

Full guide: `documentation/ticket-handling.md`. Quick reference:

```bash
sudo scripts/soc-ticket list                        # open + in_progress, every role
sudo scripts/soc-ticket list --role specialist       # just one folder
sudo scripts/soc-ticket list --status all            # include closed
sudo scripts/soc-ticket list --type incident         # restrict to one type
sudo scripts/soc-ticket show <path>                  # full content
sudo scripts/soc-ticket comment <path> "text"        # append a Comments line, author=user
sudo scripts/soc-ticket close <path> ["comment"]     # status:closed + CLOSED_ rename, atomic
sudo scripts/soc-ticket reopen <path>                # undo a close
sudo scripts/soc-ticket reassign <path> <role>        # move + chown to another role's folder
```

Never hand-edit a ticket's frontmatter -- `close`/`comment` keep `status:` and the
filename in sync atomically; a manual edit risks the split-brain bug this project
already hit once.

**What actually needs you** (per `ticket-handling.md`): anything in `user/`,
`type: missing_logs`, `type: permission_gap` -- only a human can close these.
Everything else, a role owns; you're only checking, not required to act.

## Running a role by hand -- `soc-run-role`

Full guide: `documentation/running-roles-manually.md`. All four roles run on live
systemd timers (`analyst` hourly `:00`, `specialist` hourly `:20`, `tuner-dev`
every 5h `:40`, `soclead` nightly/weekly) — this is how you trigger any of them
by hand, outside their schedule.

```bash
sudo scripts/soc-run-role <analyst|specialist|tuner-dev|soclead>
sudo scripts/soc-run-role --watch <role>        # follow the live transcript
sudo scripts/soc-run-role --watch -v <role>     # + the model's thinking blocks
sudo scripts/soc-run-role --print <role>        # dry run: print the command, don't execute
```

Skipped (not queued, exits 0) if: `PAUSED` exists at the repo root, that role's
previous run is still going (flock), or its daily cap is already hit. Replay any
past run afterward with `sudo scripts/soc-transcript <role>` (`--list` to pick a
session, `-f` to follow one live, `--thinking` for reasoning blocks).

## Notifications -- `soc-notify`, and two non-LLM safety nets

```bash
scripts/soc-notify <low|medium|high|critical> "<subject>" <body-file>
```

**`agent-watchdog` and `soc-escalate` send REAL notifications to your phone the
moment their trigger condition is true** -- they are not dry-run/preview tools.
`agent-watchdog` pages `high` for any role whose `agent-logs/<role>.log` is stale
past ~2x its expected cadence (this fires immediately after a fresh `agent-logs`
reset, since every role looks "stale" until it runs again -- don't run it just to
look, expect real pages if logs are fresh/empty).
`soc-escalate` (root only) files a real `permission_gap` ticket + notification for
any new `permission-audit/<role>.log` entry since its last checkpoint, plus a
separate `prompt_drift` ticket if one denial shape repeats >=3x in a batch.
If you wire `agent-watchdog` to a live cron (every ~5 min,
`soc-agent-watchdog.timer` -- not installed automatically, see the
deployment guide), you can still run it by
hand too. `soc-escalate` also isn't only-manual: it fires
automatically from `soc-run-role`'s post-run periodic gate (at most hourly,
alongside `heal-permissions --all` and `context-balloon-scan` -- see
"Housekeeping scripts" below), so running any role can send real pages:

```bash
scripts/agent-watchdog          # no args; --help is not supported
sudo scripts/soc-escalate        # root only; reads role-owned 600 audit logs
```

## SIEM pipeline health (headless-siem)

```bash
siemctl stats --after <ISO8601>              # event counts + field coverage
siemctl alerts --window 15m                  # recent alerts
sudo soc-restart-pipeline                    # symlinked onto PATH, runs from anywhere
```

`soc-restart-pipeline` takes no arguments, checks 5 fixed units
(`headless-siem-{normalized,indexd,ruled,correlated,alert-watch}`), and **only
restarts a unit that isn't already active** -- safe to run anytime, never touches
a healthy service (restarting a working service blind can cause pipe-EOF/
syslogd-crash-shaped incidents downstream, which is why this check exists).

For querying/searching event data, see the **`siemctl` skill** (lives alongside
this one, in headless-siem's own `.claude/skills/` directory) -- this file only
covers service-level ops, not the query DSL.

## Deploying a fix (headless-siem)

Full guide: `documentation/tuner-dev-branch-merge.md` for the review/merge half.

**`scripts/tuner-review <ticket-path>`** automates that guide's mechanical
steps end to end (no LLM involved): parses the ticket's `Branch:` line,
fetches it, shows a merge-base-scoped diff (immune to unrelated master
drift), runs `cargo test` for every touched crate as a hard gate, and —
only after you approve — merges, pushes, redeploys touched
binaries/config, runs `check-deploy-drift`, prompts for a live-verification
note, and closes the ticket. Doesn't auto-restart services (prints which
units need it) or auto-delete the branch (asks). Also detects the
"already merged but git ancestry doesn't show it" case (a branch merged
by squash/cherry-pick rather than `git merge` — seen live with
`tuner-dev/indexd-watch-survives-wipe`) via per-file content comparison
against master's current tip, not commit ancestry.

Once merged to `master` (by hand, or via `tuner-review` above):

```bash
cd /home/user/projects/headless-siem
sudo scripts/redeploy-binary <normalized|indexd|ruled|correlated|siemctl> [--restart]
sudo scripts/check-deploy-drift          # confirm deployed == merged, and running == on-disk
```

(unlike `soc-restart-pipeline`, these two aren't symlinked onto `PATH` -- run them
from the repo.)

"Merged" and "deployed" are different things in this project -- `redeploy-binary`
without `--restart` only updates the on-disk binary; an already-running service
keeps its old code until restarted. Config changes (`config/*.toml`,
`config/rules/*`) need a separate manual `cp` to `/etc/headless-siem/` --
`redeploy-binary` only ever touches one compiled binary.

## Manifest/permission changes (this repo)

Manifests (`soc-structure/manifests/manifest-enforced-<role>.json`) are also
"merged ≠ deployed": editing the repo copy does nothing until it's copied to
`/etc/soc/` and settings are rebuilt:

```bash
sudo cp soc-structure/manifests/manifest-enforced-<role>.json /etc/soc/
sudo scripts/soc-build-settings <role>     # omit <role> to rebuild all 4
```

**`scripts/hook-check` itself is the same "merged ≠ deployed" trap** — every
role's `PreToolUse` hook actually runs `/etc/soc/hook-check`, a plain `cp`
(not a symlink), so editing the repo copy (matcher logic, not manifest data)
does nothing until it's redeployed too:

```bash
sudo cp scripts/hook-check /etc/soc/hook-check
```

No `soc-build-settings` step needed for this one — the settings files only
reference the hook by path, they don't embed its contents.

**Drift check** (confirm every deployed copy still matches the repo before
trusting an enforce-mode decision, or after any manifest/hook-check edit):

```bash
for f in hook-check manifest-enforced-{analyst,soclead,tuner-dev,specialist}.json; do
  src=$([ "$f" = "hook-check" ] && echo scripts/hook-check || echo "soc-structure/manifests/$f")
  sudo diff -q "/etc/soc/$f" "$src" || echo "DRIFT: $f"
done
```

No dedicated drift-check script exists for this repo (unlike headless-siem's
`check-deploy-drift`, which covers compiled binaries) — file copies are
simple enough that the loop above, run by hand after a permission-boundary
change, has been sufficient so far.

## Housekeeping scripts

All root-only, all safe to re-run (idempotent/checkpointed). The first three
also run automatically from `soc-run-role`'s post-run periodic gate (at most
once per 60 min); the last runs from a live weekly systemd timer.

```bash
sudo scripts/heal-permissions <role>|--all   # re-assert owner/mode on role files (drift backstop)
sudo scripts/context-balloon-scan            # flag new >=200KB tool-results; files context_balloon ticket + low notify
sudo scripts/soc-escalate                    # see Notifications above
sudo scripts/soc-session-cleanup --dry-run   # preview; real runs come from soc-session-cleanup.timer (weekly)
```

`soc-session-cleanup` deletes role session transcripts older than 14 days
(override: `--days N`, or `echo N | sudo tee /etc/soc/session-cleanup-days`);
it skips any role whose `soc-run-role` lock is held. See the script's own
`--help`/header comment for details.

## Other useful scripts

- `scripts/capture-baseline` -- snapshot current `siemctl stats`/`digest` output
  to `soc_context/baselines/<date>.{txt,json}` for later before/after comparison.
- `rdap-lookup <ip>` (installed `/usr/local/bin/rdap-lookup`, unprivileged,
  no sudoers rule) -- RDAP registration lookup for one IP, prints registrant
  org/RIR handle/CIDR/country. Allow-listed for `analyst`/`specialist` (their
  first outbound-internet call, safe because the script — not the caller —
  controls the request shape; see the script's own docstring) for verifying
  a runbook's "known-benign registered range" entries, e.g.
  `runbooks/haproxy.md`'s office/admin-access table. Installed via
  `sudo bash soc-structure/provision/12-rdap-lookup.sh` (idempotent, same
  pattern as `08-ticket-route.sh`). Operator use is the same command, no
  `sudo` needed: `rdap-lookup 203.0.113.42`.
- `PAUSED` (a file at the repo root, root-owned) -- the kill switch. Its mere
  *presence* silently skips every role run and every `soc-notify` call, no output.
  `sudo touch PAUSED` / `sudo rm PAUSED`.

## What this skill deliberately does NOT cover

- The `siemctl` query DSL and indexed-field reference -- see the `siemctl` skill.
- Ticket format spec (frontmatter fields, who may close what) -- see
  `ticketing-system/system.md`.
- Sandbox/permission model internals -- see `soc-structure/runner-and-permissions.md`.
- This skill is *not* loaded into any of the four SOC roles' own sessions (their
  manifests deny the `Skill` tool entirely, and their sandboxes' cwd/add-dirs never
  reach `.claude/skills/` in a way that would matter even if they didn't) -- it's
  for you, the operator, only.
