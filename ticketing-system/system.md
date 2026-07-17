# File-based ticketing system

Tickets are markdown files. Concurrency safety for overlapping crons (the
analyst runs every 10 min, the specialist hourly, etc.) rests entirely on
the ownership rule below — there are no locks, so follow it exactly.

## Concurrency / ownership rule

**Only the assignee — the owner of the folder a ticket currently sits in —
may edit or move that ticket.** Assignment is a one-way atomic `mv` into
another user's folder. A role that moves a ticket to reassign it does not
edit it afterward (edit-then-move, never move-then-edit). This is the
entire race-condition story: since only one role ever touches a ticket at a
time, and moving is atomic, two crons can never write the same file
concurrently.

**Exception: a human may always append a
`Comments` line to any ticket, in any folder, regardless of who currently
owns it.** This is append-only, same as every other comment — a human
never edits or removes a prior line, moves the ticket, or changes
`status`/any frontmatter field directly, only appends a new
`- <ISO 8601> user: <text>` line. This is what lets a specialist's
`in_progress` escalation (see `prompts/specialist.md`) actually receive a
reply: the ticket is otherwise still only ever edited by its owning role,
so this doesn't reopen the race-condition story above, it just adds one
specific, narrow write path for the one participant who isn't a cron.
Escalation notification bodies (every `soc-notify` call accompanying a
ticket) should always name the specific ticket file so the human knows
exactly where to reply.

**Second exception: the
original issuing role may also append a `Comments` line — append-only,
same constraints as above — to a ticket it itself filed, even after
that ticket has moved to a folder it doesn't own.** Without this,
`prompts/tuner-dev.md`'s branch-stacking behavior (append a note to an
already-filed review ticket in `user/` when a later run adds another
commit to the same branch) would have no folder it's actually allowed
to write to. Scoped narrowly: only the role named in that ticket's own
`issuer:` frontmatter field may use this, only to append, never to
edit/move/close — identical shape to the human exception above, just a
second specific writer rather than a general one.

**Residual risk, both exceptions:** neither specifies any locking, so a
genuinely simultaneous append (a human replying at the exact moment the
issuing role's own cron appends a follow-up, or either racing the
ticket's current owner doing its own read-modify-write edit) can still
lose an update — whichever write's read-modify-write cycle finishes
last wins, using the other's pre-edit content as its base. In practice
this window is narrow (human replies are triggered by an escalation the
role has typically already paused for; a role's own follow-up append
happens on its fixed cron cadence, not continuously) and the failure
mode is a missed comment, not data corruption or a security issue — but
implementers should treat "append-only" here as reducing the blast
radius of a lost update, not as a substitute for actual file locking if
this ever needs a stronger guarantee.

## Timestamps — two different formats, do not mix them up

This spec uses **two different UTC timestamp formats** for two different
purposes. Found 2026-07-11 (`agent-logs/analyst.log` line 27,
`20260711T112549Z` where every other line reads `2026-07-11T11:25:49Z`):
a role can blend the two, most likely because it had just used the
compact filename form seconds earlier when filing a ticket and carried
that shape into the next thing it wrote. Always run the actual command
below rather than freehand-formatting the current time — don't just
pattern-match against a nearby example.

- **Filenames** (this section, below): compact, no `-`/`:`, milliseconds,
  no trailing `Z`. Command: `$(date -u +%Y%m%dT%H%M%S).$(date -u +%N | cut -c1-3)`
  → e.g. `20260703T211045.482`. (Don't use `date +%3N` for the
  milliseconds field — on this host's `date` build it prints full
  nanoseconds instead of truncating; `date +%N | cut -c1-3` is the form
  already confirmed to work here.)
- **Everything else** (frontmatter `created`/`closed`, `Comments` lines,
  `agent-logs/<role>.log` lines): standard ISO 8601 extended, `-`/`:`
  separators, trailing `Z`, no fractional seconds. Command:
  `$(date -u +%Y-%m-%dT%H:%M:%SZ)` → e.g. `2026-07-11T11:25:49Z`.

Every `<ISO 8601 ...>` placeholder below in this doc, and in every role
prompt's own copy of these sections, means the second (extended) form
unless it's specifically the filename.

## Filename spec

```
<yyyymmdd>T<hhmmss>.<ms>_<slug>.md
```

- `yyyymmdd` / `hhmmss.ms` — creation time, UTC, from the **filename**
  command above. This is the ticket's **original date** and never
  changes on reassignment, even though the file moves between folders.
- `slug` — short kebab-case subject (e.g. `ssh-brute-force-canary1`).
- The `T` separator and millisecond field exist specifically so two tickets
  created in the same second don't collide.

Example: `20260703T211045.482_ssh-brute-force-canary1.md`

A closed ticket is renamed with a `CLOSED_` prefix on the filename,
otherwise unchanged: `CLOSED_20260703T211045.482_ssh-brute-force-canary1.md`.
The rename is a convenience for `ls`/`grep`; it is not the authoritative
closed/open signal — see `Status` below.

**A role closing a ticket it owns (`specialist`, `tuner-dev`, `soclead` —
see the type table below for which role closes which type) must use
`ticket-close <path> ["comment"]`** (`scripts/ticket-close`), not a raw
`mv` + hand-edited frontmatter. `ticket-close` does the optional
`Comments` append, `status: closed`, `closed: <timestamp>`, and the
`CLOSED_` rename in one atomic call. Watch out for a raw `mv` used for
this same-folder rename instead: it's easy to forget to allow-list, which
is harmless under audit mode (logged, not blocked) but a real, silent
`DENY` in enforce mode — `status: closed` could get set while the rename
never happens, leaving the ticket in a split-brain state indistinguishable
from a bug at a glance. No privilege escalation needed — the ticket
already sits in the caller's own folder, already in the caller's own
`ReadWritePaths` — this is purely a missing Bash-allowlist entry, the
same shape as `ticket-reassign`'s own fix.

## Ticket format

Real YAML frontmatter (machine-parseable), delimited by `---`, followed by
a markdown body. Do not put `Subject`/`Details`/`Comments` inside the
frontmatter block — they're body content in every ticket, agents will
otherwise produce inconsistent shapes.

```
---
issuer: <role name, e.g. analyst>
type: <bug|feature|suggestion|noise|tuning|parsing_error|missing_logs|incident|permission_gap|prompt_drift|context_balloon>
priority: <low|medium|high|critical>
status: <open|in_progress|closed>
created: <ISO 8601 timestamp — $(date -u +%Y-%m-%dT%H:%M:%SZ) — matches the filename's date/time>
closed: <ISO 8601 timestamp — $(date -u +%Y-%m-%dT%H:%M:%SZ) — empty until closed>
assigned_to: <dest role — only meaningful while the ticket sits in
  unassigned/; see Mechanism below. Not present on tickets that were
  never routed through unassigned/ (e.g. edited in place by their owner).>
---

## Subject

<short description>

## Details

<extensive description — reference alert rule name, timestamp, entity IDs,
siemctl query used, etc. Enough for the assignee to act without re-deriving
context.>

## Comments

- <ISO 8601 timestamp — $(date -u +%Y-%m-%dT%H:%M:%SZ)> <role>: <text>
- <ISO 8601 timestamp — $(date -u +%Y-%m-%dT%H:%M:%SZ)> <role>: <text>
```

**`status` is authoritative** for open/in_progress/closed — not the
filename. The two can't drift because `status: closed` and the `CLOSED_`
rename happen in the same edit, by the same role, right before the ticket
stops being touched.

**Comments are append-only**, one line per comment, format
`- <ISO timestamp> <author>: <text>` (extended form — see Timestamps
above, `$(date -u +%Y-%m-%dT%H:%M:%SZ)`). Never edit or remove a prior
comment line — append a new one instead, even to correct something.

## Type → default assignee → who may close

| Type | Default assignee | Who may close |
|---|---|---|
| `incident` | `specialist` | `specialist` (or user, via a comment instructing closure) |
| `bug` | `tuner-dev` | `tuner-dev` |
| `feature` | `tuner-dev` | `tuner-dev` |
| `suggestion` | `soclead` or `tuner-dev` (whichever role it was filed to) | that role |
| `noise` | `tuner-dev` | `tuner-dev` |
| `tuning` | `tuner-dev` | `tuner-dev` |
| `parsing_error` | `tuner-dev` | `tuner-dev` |
| `missing_logs` | `user` | `user` |
| `permission_gap` | `user` | `user` |
| `prompt_drift` | `user` | `user` |
| `context_balloon` | `user` | `user` |

`prompt_drift` (a single denial shape repeating ≥3× in one `soc-escalate`
batch — filed `low`, re-filed `medium` if the same shape recurs across
runs) and `context_balloon` (`scripts/context-balloon-scan` found a new
oversized tool-result file in a role's session state) are filed only by
`soc-infra`'s deterministic scripts, never by an LLM role.

`incident` is the type the analyst uses when escalating suspicious activity
to the specialist — this was previously unnamed in the role spec; it's now
pinned here and in `../soc-structure/overall.md`.

`permission_gap` has two filers (amended 2026-07-12, operator decision —
fable-review S1):

1. **The role itself, at the moment a denial actually blocks its task.**
   Per every role prompt's "Checking your own permissions" section: when
   the manifest genuinely has no allowed path to something the run
   needs, the role files a `permission_gap` ticket to `user` (via
   `unassigned/` + `assigned_to: user`) with the exact denied command
   and what it was for, then gives up on that path for the run — no
   retries, no workarounds. `issuer: <role>` marks these.
2. **`scripts/soc-escalate`** (the deterministic, non-LLM wrapper,
   `runner-and-permissions.md` §8) as backstop: it sweeps
   `permission-audit/*.log` and files a ticket for any denial nobody
   self-reported — e.g. a denial the model never clearly saw, or a run
   that failed before it could file. `issuer: soc-infra` marks these.

The `issuer:` field is how a reviewer tells the two apart. Resolving one
is a manual step outside the ticket system itself: edit the named
`/etc/soc/manifest-enforced-<role>.json` (add the allow pattern) or leave it
denied, then close the ticket noting which.

A ticket assigned to `user` waits for a human; no agent role may close a
`user`-assigned ticket on the human's behalf.

## Folders / users

Tickets are assigned to a user by moving the file into the folder matching
that user's name. Reassignment is done the same way — moving, never
copying. Unassigned tickets live in `unassigned`. If a folder for a known
user doesn't exist yet, create it.

**Mechanism (not just convention): the cross-folder move happens outside
any role's sandbox, driven by the ticket's own `assigned_to:` field.**
Each role runs as its own Unix user inside a hardened sandbox and a
role's folder is writable only by that role — so a role *cannot* directly
drop a file into another role's folder even if its prompt is compromised.
A role calling `sudo /usr/local/bin/ticket-assign <src-path> <dest-role>`
itself, synchronously, does **not** work — `ProtectSystem=strict` keeps
the calling role's own mount namespace read-only outside its
`ReadWritePaths` regardless of privilege escalation (`sudo` doesn't create
a new mount namespace), so the `mv` into another role's folder fails
every time, in both audit and enforce mode. Widening
`ReadWritePaths` to cover other roles' folders was considered and
rejected: it would let a role bypass every check `ticket-assign` performs
(filename shape, no-clobber, correct chown) via a plain write, reversing
the exact invariant this paragraph opens with.

The mechanism now, in three steps:

1. A role files a new ticket into `ticketing-system/unassigned/` (still
   needs no helper — that folder is group-writable) with `assigned_to:
   <dest-role>` set in its own frontmatter — normally the type table's
   default assignee below, occasionally a deliberate override (e.g.
   `prompts/tuner-dev.md`'s review tickets always go to `user`).
   **Reassigning a ticket the role already owns** (sitting in its own
   folder, not a brand-new one) is the one other case, and needs its own
   helper — `ticket-reassign <path> <dest-role>` — since the role can't
   write into `unassigned/` under a name that's actually a *move* of an
   existing owned file without validating that ownership first; it
   stages the same `unassigned/` + `assigned_to:` state as step
   1, just reached from a different starting point. Never a raw `mv` —
   not allow-listed, and only appears to work under audit mode, which
   never blocks anything.
2. The role may run `ticket-route <path>` — no privilege needed, it just
   re-checks `assigned_to:` against the same destination allowlist
   `ticket-assign` itself enforces (**never `analyst`**, never
   `unassigned` — see below) — for same-turn feedback on a typo'd or
   forbidden destination, instead of finding out only once the ticket is
   later noticed stuck.
3. `soc-run-role` — root, unsandboxed, the same trusted process that
   already starts and stops every role's run — sweeps `unassigned/` after
   each invocation (`scripts/ticket-route-sweep`), and for every ticket
   with a resolvable `assigned_to:` calls the same, **unmodified**
   `ticket-assign <src-path> <dest-role>`. Run from outside any role's
   mount namespace, the `mv` succeeds; `ticket-assign` itself still
   performs every check it always did (source containment, filename
   shape, no-clobber, chown to the destination role) — nothing about that
   trusted helper changed, only *who* calls it and *from where*.

A ticket with no `assigned_to:` yet, or an unresolvable one, is left in
place by the sweep and logged to
`permission-audit/ticket-route-sweep.log` — not silently dropped, but
nothing pages a human for it directly; it surfaces via `soclead`'s
existing stale-ticket scan noticing an old file sitting in `unassigned/`.
See `../soc-structure/runner-and-permissions.md` §4 for the full
contract.

**`analyst` is not a real queue.** No
ticket `type` routes there by default, and no role drains it — the
folder exists only for symmetry with the other roles' folders. The
analyst is a classifier that runs a fixed 10-minute loop over fresh
data, not a ticket worker with a backlog to work through. **Nothing may
be assigned to `analyst`** — if a ticket would otherwise land there,
that's a sign it's mis-typed or mis-routed; fix the routing rather than
letting it sit in a folder nothing drains.

Known users (folders):

```
unassigned
analyst
specialist
tuner-dev
soclead
user
```

`tuner-dev` is a single merged role/folder (the earlier draft of this spec
and `soc-structure/overall.md` disagreed — one cron drained two folders
`tuner`/`dev`; this is now one folder, one role, matching the one cron that
was always run). `user` is a genuine ticket destination — `missing_logs`
tickets and any specialist/tuner-dev escalation that needs a human decision
land here — and was missing from the users list before this rewrite.

## Agent logs

Every agent run (every role, every cron trigger) appends exactly one line
to `../agent-logs/<role>.log` (one file per role, so concurrent appends
from different roles never interleave mid-line):

```
<ISO 8601 timestamp> role=<role> result=<clear|triaged|escalated|closed|...> tickets=<comma-separated filenames or ->  notes="<short free text>"
```

Timestamp is the extended form from Timestamps above
(`$(date -u +%Y-%m-%dT%H:%M:%SZ)`) — **not** the compact filename form,
even if you just used that form seconds earlier filing a ticket in the
same run (see Timestamps above for why this specifically needs calling
out).

**The whole thing must be ONE `Bash` call, and that call must be a
single line — nothing else in the same call, before or after.** The
permission hook splits a compound command on every unquoted newline
before matching, so anything beyond the `echo` itself in the same call
gets parsed as a separate "subcommand" and NOMATCHes the whole thing —
this includes the obvious case (a heredoc body) but ALSO a separate
`TS=$(date ...)` assignment line before the `echo`, or a `tail -3
agent-logs/<role>.log` verification line after it (found live
2026-07-11 in both `permission-audit/analyst.log` and `permission-audit/
specialist.log` — allowed in audit mode since NOMATCH just logs there,
but a hard DENY once enforce mode is back on). Inline the `date` call
directly inside the `echo`, don't capture it to a variable first, and
don't chain a verification command after it — if you want to confirm
the write, do that as its own separate `Bash` call:

```
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) role=<role> result=... tickets=... notes=\"...\"" >> agent-logs/<role>.log
```

Double quotes inside `notes=` backslash-escaped as shown. `echo` is
exempt from the allow-list entirely (hook-check's shared
read-only-builtin set), so this single-line form always works
regardless of what else is in your manifest — the moment you add a
second line to the same call, that guarantee no longer applies.

This is the only data source `soclead`'s reports aggregate over — if a role
doesn't log, its work is invisible to reporting.
