# User escalation / notification channel

## Channel

**ntfy.sh public instance**, by default — simple to set up (a single
`curl -d` call, phone app for push), no extra infrastructure. Generate
your own random topic before deploying (see the deployment guide step
3) — never reuse the placeholder value `config/notify.conf` ships with.
A long/random topic string is the practical mitigation for using the
shared public server: nobody stumbles onto it by guessing, but anyone
who *does* learn it can read (and inject fake) your notifications, since
the public instance has no access control beyond topic secrecy.

**Self-host later:** server and topic both live in
`config/notify.conf`, not hardcoded in the script — switching
to a self-hosted ntfy instance later is a one-line edit
(`NTFY_SERVER=https://ntfy.your-domain.example`), no script changes.

Alternatives worth considering instead: email via sendmail (works, but
adds an MTA dependency); webhook to a chat app (fine, but another
external dependency/account to manage). ntfy is the default here for its
low setup cost, not because the alternatives are worse.

## Wrapper script

Every role that needs to reach a human calls exactly one script — no role
talks to ntfy directly. This keeps the rate-limit and pause-flag logic in
one place.

Implemented at `scripts/soc-notify` (reads
`config/notify.conf` for `NTFY_SERVER`/`NTFY_TOPIC`, and
`PAUSED`/`.notify-count/` relative to its own location — so it works run in
place, no install step required for local/dev use). At deploy time, symlink
or copy it onto `PATH`:

```bash
ln -s /path/to/this/repo/scripts/soc-notify /usr/local/bin/soc-notify
```

so every role's `SOC_NOTIFY_SCRIPT=/usr/local/bin/soc-notify` (see
`headless-siem/config/notify/alert-watch.sh` and the role prompts) resolves
the same way regardless of where this repo is checked out.

```
soc-notify <priority> <subject> <body-file> [type]
```

- `<priority>`: `low | medium | high | critical`
- `<subject>`: short string, becomes the notification title
- `<body-file>`: path to a file with the notification body (ticket
  reference, findings summary, etc. — not inline on the command line, so
  multi-line content and content containing shell-special characters is
  safe)
- `[type]`: optional alert-type tag, checked against
  `config/notify-types.toml` (see "Per-type ntfy filtering" below). Every
  LLM-role invocation in this doc omits it and is unaffected — fail-open,
  always sends.

Exit code 0 on successful delivery, non-zero otherwise (a role should log
the failure to `agent-logs/` but must not retry-loop on a notify failure).

**Sandboxed role invocation, enforce mode:** the bare `soc-notify
<priority> ...` form above is for human/manual use only. A role running
inside its `systemd-run` sandbox must go through the `soc-infra`
sudoers rule (`/etc/sudoers.d/soc-notify`, keyed to the absolute repo
path, not the `/usr/local/bin` symlink) and each manifest's matching
allow entry:

```
sudo -u soc-infra /home/user/projects/llm-soc-toolkit/scripts/soc-notify <priority> <subject> <body-file>
```

Check any new role prompt's usage example against this one, not against
the plain wrapper description above: only the `sudo -u soc-infra` form is
granted in a sandboxed role's manifest, and `sudo` itself only works at
all inside these sandboxes because `NoNewPrivileges` is deliberately not
set on the units (`runner-and-permissions.md` §5.1) — setting it breaks
`sudo` entirely (it structurally cannot coexist with `sudo`; the kernel
property it sets is inherited by every descendant process).

## Who may call it, at what priority

| Role | Priorities allowed | When |
|---|---|---|
| `analyst` | `high`, `critical` only | Direct notification alongside filing the specialist ticket, to close the latency gap on the specialist's own cron cadence. Also `high`, alongside a `bug` ticket to `tuner-dev` (see `prompts/analyst.md`'s pipeline-health check), when `soc-restart-pipeline` fails to bring a downed local SIEM component back up, or when pipeline-down tickets are recurring in a short window. This is the one case an `analyst` notification isn't tied to a security incident — the SOC's own blindness is itself worth reaching a human for, not just queued behind tuner-dev's longer cron interval. |
| `specialist` | `low`–`critical` | Escalating an investigated ticket to the user; low/medium for informational findings, high/critical for confirmed incidents. |
| `tuner-dev` | `low`, `medium` | Filing a review-ticket notification for a proposed suppress.toml/config change (see overall.md's tuner-dev guardrail). Never `high`/`critical` — tuner-dev doesn't handle live incidents. |
| `soclead` | `low` only | Pointing at a freshly written daily/weekly report doc. |
| `agent-watchdog` (not an agent role — see below) | `high` only | A role's `agent-logs/<role>.log` has gone stale past ~2x its expected cadence. |
| `soc-escalate` (not an agent role — see below) | `low` (audit mode) or `medium` (enforce mode) | New entries appeared in a role's `permission-audit/<role>.log` since the last check — a permission-manifest gap, either being tuned (audit) or actually blocking something in production (enforce). Also files a separate `prompt_drift` notification at `low` — `medium` if the same shape recurred across runs — when a single denial shape repeats ≥3× in one batch. |
| `context-balloon-scan` (not an agent role) | `low` only | A new tool-result file ≥200KB appeared in a role's session state — the context-ballooning failure mode caught early. Files a `context_balloon` ticket to `user/` alongside the notification. |

No role calls `soc-notify` for routine all-clear results — that's what
`agent-logs/` is for.

## Agent watchdog

`scripts/agent-watchdog` is a plain shell script — **deliberately not
an LLM**, so it can't share the agents' own failure modes — that checks
each role's `agent-logs/<role>.log` last-line timestamp against that
role's expected cadence and fires `soc-notify high` for any role that's
gone stale (roughly ~2x each role's own cron cadence plus slack — see
the script's own header for the per-role thresholds and how to adjust
them for your own cadences). `soclead` gets extra slack beyond the
2x-cadence formula: doubling its nightly cadence would mean a much wider
blind spot on the SOC's one human-facing report, so it gets
cadence-plus-a-couple-hours instead of a full 2x.

This exists because, without it, a dead agent cron is only caught by
soclead's nightly "role that didn't log" check — up to ~24h blind. It's
the same pipeline-silence failure mode Stage 0 already guards against for
the SIEM pipeline itself, reproduced one layer up: Stage 0 watches the
SIEM pipeline, but nothing watches the *agents themselves* without this
script.

- Respects the `PAUSED` kill switch, same as every other `soc-notify`
  caller — a paused SOC's silent agents are not an incident.
- Rate-limits its own notifications independently of `soc-notify`'s own
  cap: at most one notification per stale role per 4 hours (tracked in
  `.watchdog-state/<role>.last_notified`), not one per check, so
  running it every few minutes doesn't repage for an already-known-dead
  role. The cooldown state clears the moment a role's log becomes fresh
  again, so a genuine new staleness after a recovery notifies right
  away rather than inheriting an old cooldown window.
- A missing or empty `agent-logs/<role>.log` is treated as maximally
  stale, not skipped.
- Recommended wiring: `config/systemd/soc-agent-watchdog.{service,timer}`,
  every ~5 min, `User=soc-infra` (it has no internal `sudo -u soc-infra`
  of its own, so the unit sets the user directly rather than relying on
  the script).

## Escalation path for permission gaps

**The primary path is the role itself:** a role whose task is actually
blocked by an enforce-mode denial files its own `permission_gap` ticket
to `user` and gives up on that path — see each role prompt's "Checking
your own permissions" section and `ticketing-system/system.md`'s
`permission_gap` entry. `soc-escalate` below remains the deterministic
**backstop** for denials nobody self-reported.

`scripts/soc-escalate` is a plain shell script — **deliberately not an
LLM**, same reasoning as `agent-watchdog` — that runs after role
invocations and diffs each role's `permission-audit/<role>.log` against a
per-role line-count checkpoint (`.escalation-state/<role>.checkpoint`).
Required in **both** hook-mode stages, not just audit tuning — this is a
general escalation path for permission gaps, not only a tuning aid:

- **`audit` mode:** new log entries are `AUDIT-NOMATCH`/`AUDIT-DENYMATCH` —
  informational, nothing was actually blocked (the hook allows everything
  in this stage). `soc-notify low`.
- **`enforce` mode:** new log entries are real `DENY`s — an actual tool
  call was blocked in production. `soc-notify medium`.

Either way it files a `permission_gap` ticket directly to
`ticketing-system/user/` (no `ticket-assign` needed — that folder is
group-writable, and `soc-escalate` runs outside any role sandbox; note
the LLM roles themselves do *not* use this direct path for
`missing_logs` — their manifests have no `user/` write, they route via
`unassigned/` + `assigned_to: user`; only tuner-dev's review tickets
write `user/` directly) summarizing the new `tool_name`/`tool_input` entries, with
a verdict tally and the exact new lines (capped and truncated with a
first/last excerpt if the checkpoint was very stale). The human reviews:
add the pattern to the named `/etc/soc/manifest-enforced-<role>.json` if
legitimate, or leave it denied if the role was reaching for something out
of scope — itself a useful signal, potentially a prompt-injection
indicator worth its own look (`runner-and-permissions.md` §10).

Runs as **root**, not as `soc-infra` directly: `permission-audit/<role>.log`
is role-owned `600` + append-only (`chattr +a`) specifically so a
compromised role can't tamper with its own audit trail, which also means
no other account — `soc-infra` included — can read it without root. The
ticket it files and the `soc-notify` call it makes are both done *as*
`soc-infra` (via `runuser`) so their artifacts (the ticket file,
`.notify-count/`) stay owned consistently with every other `soc-infra`
output. Not sudoers-granted to any `soc-<role>` account — no LLM role ever
needs to invoke this from inside its own sandbox, unlike `ticket-assign`/
`soc-notify`; it's an outside-the-loop check run on the roles. It runs
automatically from `soc-run-role`'s post-run periodic-maintenance gate —
at most once per 60 minutes, alongside `heal-permissions --all` and
`context-balloon-scan` — and remains runnable by hand (`sudo
scripts/soc-escalate`).

**Pattern layer:** on top of the any-new-entry ticket above, if a single
denial shape (the `cmd=`/`file=`/`input=` token) repeats **≥3× within one
batch** — a starting value, tune it against your own real cron volume —
it files a separate `type: prompt_drift` ticket: persistent
drift (the role keeps reaching for the same out-of-manifest thing) or a
possible injection signal, distinct from one-off tuning noise. Filed at
`low`; a shape that recurs across separate runs (tracked in
`.escalation-state/<role>.patterns`) re-files at `medium` instead of
`low` forever.

## Rate limit

**Priority-aware** — a flood of `low`/`medium` traffic (or a
duplicate-incident flood from before the analyst's own dedupe) could
otherwise silently starve a genuine `critical` page for up to an hour,
since a single shared 10/hour cap dropped by arrival order regardless of
priority. Instead there are two independent buckets, both tracked by the
wrapper itself via counter files under `.notify-count/<hour-bucket>.*`:

- **`critical` has its own separate 10/hour cap**, entirely independent
  of `low`/`medium`/`high` traffic — still bounded (a runaway agent
  can't page 144×/day), but never starved by anything else.
- **`low`/`medium`/`high` share a 10/hour bucket, but the last 3 slots
  of each hour are reserved for `high` only** — `low`/`medium` can fill
  at most 7 of the 10 shared slots; the remaining 3 are usable by `high`
  regardless of how much `low`/`medium` volume already arrived that
  hour.

When a cap is hit, further calls of that priority tier are dropped and
counted; the wrapper still exits 0 (so the calling role doesn't treat a
rate-limited drop as a hard failure) but appends a note to its own log.
At the start of the next hour bucket, if anything was dropped in the
prior hour (either bucket), the wrapper's first successful send that
hour prepends a one-line summary: `N notification(s) suppressed in the
prior hour — see agent-logs/` (`N` is the combined total across both
buckets).

## Per-type ntfy filtering

`config/notify-types.toml` lets specific alert *types* be silenced
without touching ticket filing — the ticket is still written to
`ticketing-system/user/` exactly as before either way; only the ntfy
push (the phone page) is skipped. This is separate from the `PAUSED`
kill switch (which silences everything) and from priority-based
routing (which caller may send at what priority) — it's a per-type
on/off switch layered on top of both.

Only the two deterministic backstop scripts currently pass a type:
`soc-escalate`'s `permission_gap` notification and
`context-balloon-scan`'s `context_balloon` notification. Neither
script's *ticket* filing reads this file — only the `soc-notify` call
does. `soc-escalate`'s separate `prompt_drift` notification, and every
LLM-role `soc-notify` call in the table above, doesn't pass a type and
so always sends regardless of this file's contents.

Format is a flat `type = true|false` list; a value of exactly `false`
skips the send, anything else (including the key being absent, or the
file itself missing) fails open and sends. Skipped sends are logged to
stderr (`[soc-notify] skipped (disabled in config/notify-types.toml):
...`) and don't consume rate-limit quota.

## Kill switch interaction

`soc-notify` (and every role invocation) checks the
`PAUSED` flag file before doing anything. If
present, exit 0 immediately with no notification sent and no counter
increment — a paused SOC is silent by design, not spamming "I'm paused"
messages.
