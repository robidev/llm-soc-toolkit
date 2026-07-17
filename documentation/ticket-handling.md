# Ticket handling — a human's guide

This is the **operator-facing how-to**: the practical steps for reading,
assessing, commenting on, and closing tickets. For the machine-facing
format spec (frontmatter fields, filename rules, who may close what type)
see `../ticketing-system/system.md` — this document doesn't repeat that,
it tells you what to actually *do* with it.

## Where tickets live

One folder per current owner, under `../ticketing-system/`:

```
ticketing-system/
  analyst/       specialist/     tuner-dev/      soclead/      user/
  unassigned/    (transient — a routing sweep drains this after every role run)
```

An open ticket's filename has no prefix; a closed one is renamed with a
`CLOSED_` prefix. `status:` in the frontmatter is the authoritative
open/in_progress/closed signal — the filename prefix always matches it,
so either works, but scripts and greps should check `status:`.

## The one tool you need: `soc-ticket`

Root-only by design (`ticketing-system/system.md` — this is deliberately
**not** something a sandboxed role can invoke; a role hits its own
`ticket-close`/`ticket-reassign`/`ticket-route` helpers instead, which are
narrower). Run it with `sudo` from `/home/user/projects/llm-soc-toolkit`:

```bash
sudo scripts/soc-ticket list                        # open + in_progress, every role
sudo scripts/soc-ticket list --role specialist       # just one folder
sudo scripts/soc-ticket list --status all            # include closed too
sudo scripts/soc-ticket list --type incident         # restrict to one ticket type
sudo scripts/soc-ticket show <path>                  # full ticket content
sudo scripts/soc-ticket comment <path> "text"        # append a Comments line, author=user
sudo scripts/soc-ticket close <path> ["comment"]     # status:closed + closed: timestamp + CLOSED_ rename, atomically
sudo scripts/soc-ticket reopen <path>                # undo a close
```

`--role`/`--status`/`--type` combine freely. Run `sudo scripts/soc-ticket
<subcommand> --help` if a flag here looks stale — this doc isn't the
source of truth for syntax, `soc-ticket` itself is.

**Don't hand-edit a ticket's frontmatter directly.** `close`/`comment`
compute the timestamp server-side and keep `status:`/the filename in sync
atomically; a manual edit risks a "split-brain" bug class — `status:
closed` set but the file never renamed `CLOSED_`. If you're just
*reading*, `cat`/`less` the file directly — no tool needed for that.

## A daily/periodic review pass

1. **List every open ticket** across all 5 folders (`sudo scripts/soc-ticket
   list`, or `find ticketing-system -name '2*.md' ! -name 'CLOSED_*'` if
   the tool's list view doesn't give you enough). Sort by `priority` and
   age (filename timestamp) — anything `high`/`critical` or more than a
   day old gets looked at first.
2. **Read the ticket, not just the subject line.** The `Details` section
   is written to be self-contained (siemctl queries used, alert
   rule/timestamp, precedent search results) — you shouldn't need to
   re-derive the investigation yourself, just judge whether the
   conclusion is sound.
3. **Check who it's actually waiting on.** `assigned_to:` in a ticket
   still sitting in `unassigned/` means the routing sweep hasn't run yet
   (happens automatically after every role invocation — don't hand-route
   it, it'll clear on its own). A ticket already sitting in a role's own
   folder is that role's queue; only `user/` tickets and specifically
   Canary-policy incidents (below) are waiting on **you**.

## What specifically needs a human

Most tickets get closed by the role that owns them (see
`system.md`'s Type → default assignee → who may close table) — you don't
need to touch those unless something looks wrong. Three things are
different:

- **`type: missing_logs` / `type: permission_gap` tickets, and anything
  filed straight to `user/`** — these are *only* closable by a human;
  no role will ever close one on your behalf, by design (`system.md`:
  "A ticket assigned to `user` waits for a human; no agent role may close
  a `user`-assigned ticket on the human's behalf"). If you don't look at
  these, they sit forever.
- **Canary-policy incidents.** Any ticket touching canary1/canary2
  (`runbooks/environment.md`'s Canary exception) is *never* auto-closed by
  analyst or specialist, no matter how confident they are it's just the
  test harness. It'll sit `in_progress`, fully investigated, with
  a note like "escalating for the required human confirm/close" — read
  the investigation, and if you agree it's benign, close it yourself with
  a comment saying so. Don't assume "specialist already confirmed it" means
  it's already closed — it deliberately isn't.
- **`permission_gap` tickets from `soc-infra`** (issuer, not an LLM role
  — `system.md`'s note on this type). These mean a role hit its own
  manifest boundary. Resolving one means editing
  `/etc/soc/manifest-enforced-<role>.json` yourself (add the allow
  pattern) or deciding to leave it denied — either way, close the ticket
  noting which you chose.

## Filing a ticket yourself

There's no `soc-ticket create` — ticket origination is normally
role→role, not human-initiated. If you genuinely need to file one (e.g.
you found something reviewing logs/transcripts that no role has ticketed
yet), write it by hand matching `system.md`'s exact frontmatter/body
shape, `issuer: user`. The destination folder is owned by that role's
Unix account, so a plain `Write`/`cp` as yourself will get `EACCES` —
stage the file anywhere you can write (e.g. a scratch dir), then:

```bash
sudo cp <staged-file> ticketing-system/<role>/<timestamp>_<slug>.md
sudo chown soc-<role>:socroles ticketing-system/<role>/<timestamp>_<slug>.md
sudo chmod 640 ticketing-system/<role>/<timestamp>_<slug>.md
```

Filename: `$(date -u +%Y%m%dT%H%M%S).$(date -u +%N | cut -c1-3)_<slug>.md`
— see `system.md`'s Filename spec section for the exact rules (this
host's `date` is `uutils coreutils`; `%3N` does **not** truncate here,
use `%N | cut -c1-3`).

## Gotchas

- **Comments are append-only.** Never edit or remove a prior comment line
  to "correct" it — append a new one. This is enforced by convention, not
  by the tool, so it's on you as the human too.
- **A `CLOSED_` ticket can be reopened** (`soc-ticket reopen`) if you
  close something and then realize you were wrong — it's not a one-way
  door, just don't rely on that as a substitute for reading carefully the
  first time.
- **`ticketing-system/unassigned/` is not a queue you triage** — it's a
  transient landing zone, drained automatically by the post-run routing
  sweep in `scripts/soc-run-role`. If you see something sitting there for
  more than one role-invocation cycle, that's a bug (unresolvable
  `assigned_to:`, typically a typo) — `soclead`'s stale-ticket scan should
  catch it, but it's worth a manual look if you notice it yourself.
- **A role's own log (`agent-logs/<role>.log`) is the fast way to see
  *why* a ticket got filed**, in one line, without opening the ticket —
  useful for skimming a day's activity before deciding which tickets
  need a close look. `sudo scripts/soc-transcript <role>` goes one level
  deeper (the full tool-call transcript) if a one-line summary + the
  ticket body still isn't enough context.
