# Running a SOC role by hand — a human's guide

This is the **operator-facing how-to** for kicking off a role invocation
yourself instead of waiting for a schedule. For the underlying
mechanics/spec (sandbox properties, credential resolution, the analyst
two-pass) see `../soc-structure/runner-and-permissions.md` §5.1 — this
document doesn't repeat that, it tells you what to actually *run*.

## The command

```bash
sudo scripts/soc-run-role <role>
```

from `/home/user/projects/llm-soc-toolkit`, for any of the four roles:

| Role | Model | Daily cap |
|---|---|---|
| `analyst` | Haiku stage0/1, escalates to Sonnet stage2 if anomalies found | 200 |
| `specialist` | Sonnet | 48 |
| `tuner-dev` | Sonnet | 12 |
| `soclead` | Sonnet | 6 |

No `CLAUDE_BIN=...` env var needed — the script resolves the real
`claude` binary itself now. (If you're testing with a stub instead of
spending real tokens, `CLAUDE_BIN=/path/to/stub` still works to override
it — see the script's own header comment.)

A run is skipped, not queued, if: `PAUSED` exists at the repo root, the
same role's previous invocation is still running (flock), that role
already hit its daily cap, or (`specialist`/`tuner-dev` only) its own
ticket folder (`ticketing-system/<role>/`) has no open — non-`CLOSED_` —
tickets right now — each prints a one-line reason and exits 0. The
queue-empty skip still appends a line to `agent-logs/<role>.log` (so
`agent-watchdog` doesn't mistake an idle queue for a dead cron); it just
doesn't spend a daily-cap slot or touch credentials, since nothing runs.

## Watching it live: `--watch`

```bash
sudo scripts/soc-run-role --watch <role>
sudo scripts/soc-run-role --watch -v <role>   # + the model's thinking blocks
```

`claude -p` (how every role actually runs) only ever prints its final
message — there's no flag that makes it stream tool calls live. `--watch`
works around that by following the run's own session transcript file
directly (the same mechanism `sudo scripts/soc-transcript -f <role>` uses
for after-the-fact replay), so you see tool calls and results as they
happen. Flags can go in any order (`soc-run-role <role> --watch` and
`soc-run-role --watch <role>` are equivalent) — an unrecognized flag or
more than one role argument is rejected with a usage message rather than
silently ignored.

`--watch` is purely a visibility layer: sandboxing, credentials, the
daily cap, the run lock, and the post-run ticket-routing sweep are all
identical to a plain invocation.

## Dry run: `--print`

```bash
sudo scripts/soc-run-role --print <role>
```

Prints the exact `systemd-run` command(s) that would run — including
both stages for `analyst` — without executing anything. Doesn't touch
the daily cap, the lock, or any real credential/token. Useful for
checking a manifest or prompt change took effect before spending a real
invocation on it.

## Stopping a run

Ctrl-C works. The actual `claude` invocation runs inside a hardened,
detached `systemd` unit — a terminal Ctrl-C can't reach it directly, so
`soc-run-role` catches the interrupt itself and explicitly tells systemd
to stop the unit (and, under `--watch`, stops the follower too) before
exiting. You'll see `soc-run-role: caught SIGINT, stopping (unit=...)...`
and the unit disappears within a second or two — it does not run to
completion in the background after you interrupt it.

Stopping a running unit some other way — e.g. `systemctl stop` by hand
from a separate shell, bypassing `soc-run-role` entirely — is handled too,
as of 2026-07-17: analyst's stage0/1 sees empty/interrupted output with no
fence, but the wrapper now recognises the out-of-band stop (via the unit's
journal stop-job marker, since a clean `systemctl stop` returns rc=0
indistinguishably from a normal completion) and treats it as *aborted* —
it skips the expensive Sonnet stage2 pass and logs `fence=aborted` rather
than escalating with a bogus "malformed fence" ticket-suggestion. This is
narrow on purpose: a stage0/1 run that genuinely *finishes* but emits a
garbage/absent fence still fails **open** and escalates to stage2, because
silently dropping a possible anomaly is worse than an unnecessary Sonnet
call. Ctrl-C through `soc-run-role` itself remains the cleanest stop (the
script's own trap exits before the fence parser ever runs).

Known gap: `systemctl kill -s KILL` on the unit (as opposed to `systemctl
stop`) does *not* leave a stop-job marker, so it's not recognised as an
abort and still fails open to stage2 — use `systemctl stop`, not
`kill -s KILL`, if you want the run to wind down without escalating.

## Gotchas

- **A role invoked by hand shares your own interactive session's
  subscription usage window**, if the deployed credential is an OAuth
  token rather than an API key (`sudo cat /etc/soc/oauth-token` vs.
  `/etc/soc/*.key` tells you which — as of this writing it's the OAuth
  token). Running several roles back-to-back in the same session as your
  own interactive Claude Code use can hit the shared limit. A dedicated
  `ANTHROPIC_API_KEY` avoids this but isn't set up yet — see
  `runner-and-permissions.md`'s open questions.
- **`sudo scripts/soc-transcript <role>`** (no `-f`) replays the most
  recent run after the fact, without following live — faster than
  `--watch` if you just want to see what already happened.
  `sudo scripts/soc-transcript --list` shows every session across all
  four roles (id/time/turns/preview) to find one to replay.
- **`--print`/`--watch` never consume a daily-cap slot or the run lock
  by themselves** — only an actual (non-`--print`) invocation does,
  exactly once per invocation regardless of whether analyst's stage2
  fires.
