# Runner + permission architecture

This document describes the orchestration and permission system.

## 1. The two-layer security model

Two independent layers, one hard and fixed, one soft and tunable.

1. **Hard layer — Unix/OS permissions.** Each LLM role runs as its own
   dedicated Unix user inside a hardened `systemd-run` transient unit
   (§5). Filesystem ownership, mode bits, and the unit's sandboxing
   properties are the actual, unconditional boundary — a role's process
   cannot open a file it has no OS permission to open, full stop,
   regardless of what its Claude Code permission config says or how a
   prompt injection tries to steer it. Always enforced, no audit mode.
2. **Soft layer — Claude Code's own permission system** (`settings.json`
   `permissions`, the `hook-check` `PreToolUse` hook). The finer-grained
   boundary ("may run `siemctl digest` but not `siemctl retention`," "may
   call `soc-notify` only at `high`/`critical`"). This layer has a
   per-role **audit → enforce** mode — audit mode only ever
   loosens the soft layer, never the hard one underneath it.

## 2. Unix users and groups

| User | Purpose |
|---|---|
| `soc-analyst` | analyst role invocations |
| `soc-specialist` | specialist role invocations |
| `soc-tunerdev` | tuner-dev role invocations. Owns its own SIEM repo's git clone (§5.3), never the checkout live services run from. |
| `soc-soclead` | soclead role invocations |
| `soc-infra` | Non-LLM trusted helpers only: `soc-notify`, `agent-watchdog`, `ticket-assign`, `ticket-route-sweep`, `soc-escalate`, `context-balloon-scan`. Deterministic, no model involved. |

All five: no login shell. Group `socroles` = all five accounts, used for
**read-only** cross-role access (ticket tree, `agent-logs/`) — group
membership never grants write; write is always owner-only or via one of
the trusted helpers in §4.

## 3. Filesystem layout and permissions

All paths relative to this repo's root unless noted.

| Path | Owner:Group | Mode | Notes |
|---|---|---|---|
| `ticketing-system/{analyst,specialist,tuner-dev,soclead}/` | `soc-<role>:socroles` | `750` | Owner read/write, group read-only. |
| `ticketing-system/user/` | `user:socroles` | `2770` (setgid) | Human inbox. Every role can create here directly (e.g. `missing_logs`, review tickets); group-write needed for that. |
| `ticketing-system/unassigned/` | `root:socroles` | `3770` (setgid+sticky) | Staging area — every role can create here freely; sticky bit stops a role deleting/renaming *another* role's file directly. |
| `agent-logs/<role>.log` | `soc-<role>:socroles` | `640` | Owner appends; group read. |
| `runbooks/`, `documentation/`, `soc_context/`, `soc-structure/`, `prompts/`, `scripts/` | `user:socroles` | `750` dirs / `640` files | Read-only reference material for every role. Owned by the operator (`user`), not `root`, so the git tree stays developer-editable while staying role-read-only. |
| `reports/` | `soc-soclead:socroles` | `750` | soclead's write target. |
| `.notify-count/`, `.watchdog-state/` | `soc-infra:socroles` | `770` | Non-LLM helper state only. |
| `permission-audit/` | `root:socroles` | `750` dir; logs `chattr +a` | Root-owned so no role can delete/rewrite its own audit trail, only append to it. |
| `PAUSED` | `root:socroles`, `640` | Kill switch; only a human creates/removes it. |

**Any ground-truth file with real credentials/host detail you don't want
a role to read at all** (e.g. an unsanitized firewall backup, a test-host
credential list): lock it `600` root-owned, outside every role's read
tree — enforced at the OS level, not just by prompts never being told to
read it. `soc-structure/provision/01-users-and-perms.sh` applies this to
`documentation/canary-hosts.md` as a shipped example; add your own files
to that same loop.

**`CLAUDE.md` at this repo's root, and any parent-directory `CLAUDE.md`
above it: keep these `user:user`, `640`, unreadable by any `socroles`
member.** These are neither role-reference material nor secrets, just
operator-facing docs — deliberately unreadable because Claude Code
auto-discovers `CLAUDE.md` by walking every *ancestor* directory of a
session's cwd, not just cwd itself. Without this, an operator-facing
parent `CLAUDE.md` (built for interactive phone-triage use) and this
repo's own `CLAUDE.md` would both silently bleed into every role's
context on every run. An unreadable `CLAUDE.md` costs exactly the same
input tokens as no file at all — Claude Code skips it silently, no
error. The same discovery behavior applies to Skill listings: a sibling
SIEM repo's own skill would get its full listing injected into context
whenever that directory is in view (only tuner-dev's own `--add-dir`
puts it in view), *regardless* of whether the manifest allows the
`Skill` tool — being merely absent from the allow list under
`defaultMode: dontAsk` doesn't stop the discovery scan; only an explicit
`deny` entry does, which is why `"Skill"` is in
`scripts/soc-build-settings`'s `SAFETY_DENY`.

**Read/write split, restated:** every `socroles` member reads the whole
ticket tree + `agent-logs/` + reference docs. Write is always
owner-only within a role's own folder (in-place edits: append a
comment, close-and-rename) — never a direct cross-folder write for an
LLM role's own Unix user. That's what makes "the ticketing system is
the sole inter-role interface" an enforced property, not a convention a
compromised prompt could break.

## 4. Ticket routing — the one cross-folder write path

**`scripts/ticket-assign <src-path> <dest-role>`** is the one trusted
helper that actually moves a ticket between folders: it canonicalizes
and containment-checks the source (must resolve to `unassigned/` or the
caller's own folder), validates `<dest-role>` against the real folder
list (never `analyst` — not a real queue; never `unassigned` — a
staging area), refuses to overwrite an existing destination file, moves
the file, then `chown`s it to the destination role. Installed
`/usr/local/bin/ticket-assign`, root:root `755`, invoked via
`sudo`. Deterministic, no LLM involved, no argument depends on ticket
content — that's why it's trusted with elevated privilege.

**A role never calls `ticket-assign` directly** — `ProtectSystem=strict`
(§5) keeps a role's own mount namespace read-only outside its
`ReadWritePaths` regardless of `sudo`-based privilege escalation (`sudo`
doesn't create a new mount namespace), so that `mv` can never succeed
from inside a role's own sandbox. Instead:

1. A role files a new ticket into `unassigned/` (needs no helper — that
   folder is group-writable) with `assigned_to: <dest-role>` set in its
   frontmatter. To hand off a ticket it already *owns* instead (e.g.
   tuner-dev deciding a ticket is out of its scope), it uses
   **`ticket-reassign <path> <dest-role>`** — unprivileged, reads
   `CLAUDE_ROLE` (set by `soc-run-role` per invocation, not a claimed
   argument) to confirm the ticket is actually in its own folder, then
   stages it in `unassigned/` with `assigned_to:` set, same as case 1.
2. Either way, the role may run **`ticket-route <path>`** — unprivileged,
   re-validates `assigned_to:` against the same destination allowlist
   `ticket-assign` enforces — for same-turn feedback on a typo/forbidden
   destination.
3. **`soc-run-role`** (root, unsandboxed — the same process that starts
   and stops every role's run) sweeps `unassigned/` after every
   invocation via **`scripts/ticket-route-sweep`**, and for every ticket
   with a resolvable `assigned_to:` calls the real, unmodified
   `ticket-assign`. Run from outside any role's mount namespace, the
   `mv` succeeds. State-scan-based, not run-scoped, so it drains any
   backlog regardless of which role's run triggered it.

A ticket with no `assigned_to:` yet, or an unresolvable one, is left in
place and logged to `permission-audit/ticket-route-sweep.log`; surfaced
via soclead's stale-ticket scan, not paged directly.

**Filing directly into `user/`** skips all of this — it's a brand-new
ticket in an already group-writable folder, not a move of an existing
one. In practice only two writers use this path: `tuner-dev`'s review
tickets (the one LLM role whose manifest allows
`Write(ticketing-system/user/**)`) and the non-LLM `soc-escalate`
(unsandboxed, files `permission_gap` tickets as `soc-infra`). The other
roles' `user`-bound tickets (e.g. analyst's `missing_logs`) go through
the normal `unassigned/` + `assigned_to: user` route — their manifests
deliberately have no `user/` write.

## 5. Per-role process configuration

### 5.1 Invocation

`scripts/soc-run-role <role>` runs as root and launches one role's
`claude -p` invocation via a hardened transient `systemd-run` unit:

```
systemd-run --uid=soc-<role> --gid=socroles --pipe --wait --collect
  --property=ProtectSystem=strict
  --property=ProtectHome=read-only
  --property=PrivateTmp=yes
  --property=RestrictSUIDSGID=yes
  --property=ProtectControlGroups=yes
  --property=ProtectKernelTunables=yes
  --property=ReadWritePaths=<role's own dirs + unassigned/ + role-specific paths>
  --property=RuntimeMaxSec=<per-stage timeout>
  --property=EnvironmentFile=<one-time credential file, root-only, deleted on exit>
  -- claude --append-system-prompt-file <role prompt> -p "<fixed user turn>"
     --model <role model> --effort <role effort>
     --settings /etc/soc/<role>-settings.json
```

`NoNewPrivileges=yes` is deliberately **not** set — it's incompatible
with `sudo` ever working inside the process tree (the kernel property
it sets is inherited by every descendant, including `sudo` itself,
which needs setuid escalation to function). The sudoers rules
themselves stay narrowly argument-scoped, which is the boundary that
actually matters here.

**Watching a manual run**: `sudo scripts/soc-run-role --watch <role>`.
`claude -p` never streams a live tool-call transcript to stdout — no
flag changes that, it only ever emits the final message — so `--watch`
doesn't touch the `claude` invocation at all. Instead it backgrounds a
short poll (up to 60s) for this run's own new session file to appear
under the role's `~/.claude/projects/`, then execs into `scripts/
soc-transcript -f <role>` to follow it live (waiting for the new file
first avoids replaying a stale prior session from the top). Add
`-v`/`--verbose` alongside `--watch` to also include the model's
thinking blocks (`soc-transcript --thinking`). Purely a visibility
layer — sandbox, credentials, daily cap, lock, and the post-run ticket
sweep are unchanged from a normal invocation. Combine with `--print` to
see the exact command instead of running it (`--watch`/`-v` have no
effect together with `--print`, since nothing is actually run).
`scripts/soc-transcript` itself (`--list`, `--session`, `--thinking`,
replay of a past run) is documented in its own `--help`.

**Persistent memory**: each role has the same auto-memory system as an
interactive Claude Code session, scoped to its own Unix account's `$HOME`
(e.g. `/var/lib/soc/analyst`) — it survives across invocations because
that whole directory is one of the `ReadWritePaths` entries (see
`soc-run-role`'s `rw` array), not wiped like `/tmp` is. Location:

```
/var/lib/soc/<role>/.claude/projects/<mangled-cwd>/memory/MEMORY.md
```

(`<role>` is `analyst`, `soclead`, `specialist`, or `tunerdev` — matches
the directory names under `/var/lib/soc/`, not the hyphenated `tuner-dev`
role name used elsewhere.) Individual memory files sit alongside
`MEMORY.md` in that same `memory/` directory. Reading it requires `sudo`
(each role's home is owned by its own service account, group `socroles`).

`--settings /etc/soc/<role>-settings.json` is root-owned `644`,
generated by **`scripts/soc-build-settings`** from the role's manifest
(`soc-structure/manifests/manifest-enforced-<role>.json`) + its current
hook mode — never hand-edited. Re-running it is how you regenerate a
role's settings after a manifest change or a mode flip.

**Credentials**: either an `ANTHROPIC_API_KEY` (`/etc/soc/<role>.key` or
`/etc/soc/anthropic.key`) or a subscription OAuth token from `claude
setup-token` (`/etc/soc/<role>.oauth` or `/etc/soc/oauth-token`) — API
key wins if both exist. Injected via a root-only `EnvironmentFile` so
the secret never lands on a command line or in `ps` output. `--bare`
(max isolation — suppresses `$HOME/.claude` discovery) is applied only
when the role is in enforce mode **and** the credential is an API key —
`--bare` never reads an OAuth token, so a subscription-token role
running in enforce mode drops `--bare` and relies on native settings +
the role's sandbox `HOME` alone — which is **not** empty in practice: it's
a persistent, fully read-write directory across invocations (session
transcripts, credential backups, and per-role memory — see "Persistent
memory" above), so this path leaves `$HOME/.claude` discovery live. If
you deploy on a shared OAuth token rather than per-role API keys,
`--bare` never applies, regardless of mode.

### 5.2 `siemctl` access

Roles invoke `siemctl` via the pinned PATH shim (`/usr/local/lib/soc/bin/siemctl`,
root-owned), not the raw binary — the shim fences `--data-dir` to the
real data directory regardless of what a role's command line requests.
The one write `siemctl` needs from a role is `alerts ack`
(`/var/lib/headless-siem/alerts`, in the analyst/specialist
`ReadWritePaths` already). Both analyst and specialist can be allowed
to ack if you want either role's workflow to do so — that's a
prompt-level convention to decide, not something the sandbox itself
needs to enforce narrower than "these two roles may write to the
alerts store."

### 5.3 tuner-dev's git clone

`soc-tunerdev` owns a dedicated `git clone --no-hardlinks` of the SIEM
repo at `/var/lib/soc/tunerdev/<siem-repo-name>` — full ref+object
isolation from the repo any live service or human actually works from,
not a `git worktree` (which would share refs/objects writably).
`.git/refs/heads/master` is root-owned `644` so `soc-tunerdev` cannot
update it by any means, regardless of what git subcommands its session
can invoke, on top of simply never granting it push/remote credentials
at all. Its sandbox gets an offline `CARGO_HOME`
(`CARGO_NET_OFFLINE=true`) pre-populated at setup time, so a
ticket-influenced build can never fetch a new dependency.

### 5.4 Analyst two-pass invocation

`prompts/analyst.md` runs as two separate `claude` invocations, not one:

1. **Stage 0/1** (cheap/fast model, low effort): pipeline health + classification.
   Ends its final message with a fenced block —
   ` ```anomaly-status\n{"stage0_stopped": <bool>, "anomalies": [...]}\n``` `
   — that `scripts/soc-run-role` parses deterministically (no LLM).
2. If `stage0_stopped` or an empty `anomalies` list: done, nothing
   further this run.
3. Otherwise, **Stage 2** (more capable model, medium effort) re-invokes with the
   anomaly list handed off via a private per-run file
   (`/var/lib/soc/analyst/tmp/anom.<run-id>.json`, `soc-analyst:socroles`
   `600`, removed on every exit path + a periodic reaper backstop).

**Malformed-fence handling**: if the fence is absent or unparseable,
the wrapper fails **open** — escalates to Stage 2 anyway (`GO-FALLBACK`,
distinct from a clean `GO`) rather than silently dropping a possible
anomaly, and attaches Stage 0/1's raw final message so Stage 2 has a
starting point instead of blind-re-deriving the window from scratch.
Fence health (`fence=ok`/`fence=malformed`/`fence=aborted`) is logged in
`agent-logs/analyst.log` on every Stage-2 run, so the failure rate is
directly countable — this is a real, occasional small-model
instruction-following gap, not something the wrapper can eliminate,
only mitigate.

**Out-of-band-stop carve-out**: the same truncated-output symptom that
triggers `GO-FALLBACK` also appears when an operator stops the
stage0/1 unit *out of band* — `systemctl stop $CUR_UNIT` from another
shell, i.e. NOT through `soc-run-role`'s own Ctrl-C trap (which
`exit 130`s before the fence parser ever runs). Escalating to the
expensive Stage 2 there is the opposite of what the aborting operator
wanted, and the synthetic "malformed fence, file a tuner-dev bug"
anomaly is a lie — nothing was malformed, the run was killed on
purpose. So the `GO-FALLBACK` branch checks `unit_stopped_out_of_band()`
and, only in that specific case, skips Stage 2 and logs `fence=aborted`
instead. This is **additive**: a stage0/1 that genuinely *completed*
but emitted a bad/absent fence still fails open exactly as before. The
detector is the journal **stop-job marker** (`Stopping <unit>...`), NOT
the exit code — a clean `systemctl stop` (default SIGTERM) is recorded
by systemd as a *successful* stop and `systemd-run --wait` returns
**rc=0**, identical to a normal completion, so exit code alone cannot
tell the two apart. The out-of-band stop is documented as a known
caveat in `documentation/running-roles-manually.md`.

**Model-writable scratch space**: the `/var/lib/soc/analyst/tmp/` path
above is wrapper-owned and `Read`-only for the model — never a place
for it to write its own scratch files (e.g. redirecting a large
`siemctl digest`/`search` result instead of inlining it).
`prompts/analyst.md` directs that instead to
`ticketing-system/analyst/scratch-<slug>.json`, alongside the
pre-existing `notify-body-<slug>.txt` staging for `soc-notify
high`/`critical` (same directory, same "outside the ticket-frontmatter
format, but a plain filename `soc-ticket` won't glob since it only
matches `*.md`" trick). Since analyst has no `rm`/delete grant of its
own, `scripts/soc-run-role` reaps both patterns itself — same
`-mmin +60`-before-this-run's-own-files shape as the `$home/tmp` reaper
above, just scoped to `ticketing-system/analyst/` and these two filename
patterns rather than the whole directory (which also holds real
tickets). Keeps scratch/notify-body files from accumulating indefinitely
while still surviving until the role's next run, so a human can inspect
the most recent one if needed.

## 6. Per-role permission manifests

Source of truth: `soc-structure/manifests/manifest-enforced-<role>.json`
— derived from each prompt's own "Allowed tools" section. Deployed to
`/etc/soc/manifest-enforced-<role>.json` (root-owned `644`) and compiled
into `/etc/soc/<role>-settings.json` by `soc-build-settings` (§5.1).
Read the JSON, not prose, for the enforced truth — this doc doesn't
duplicate the pattern lists to avoid them drifting out of sync with
what's actually deployed.

`scripts/hook-check` itself has the identical "merged ≠ deployed" property
as the manifests: every role's `PreToolUse` hook actually runs
`/etc/soc/hook-check`, a plain `cp` of the repo file, not a symlink —
editing the matcher logic in the repo does nothing until it's redeployed.
Deploy commands and a drift-check one-liner for both: `.claude/skills/
soc-tools/SKILL.md` § "Manifest/permission changes".

`hook-check` matches three tool shapes: Bash commands (split into
subcommands on shell separators and matched piece by piece), a bare tool
name (`"ToolSearch"`, an unscoped grant), and `"Agent(<subagent_type>)"`
(scoped by subagent type — a subagent runs inside the same sandboxed UID
as its caller, so delegation itself adds no reach; the named subagent
type's own tool profile is what's actually being granted). See
`tool_decision()` in `scripts/hook-check`.

## 7. Audit-then-enforce rollout

`scripts/hook-check` (Python `PreToolUse` hook) reads a tool call from
stdin, derives the role from the running UID (never from input), checks
it against the role's manifest, and:

- **Audit mode** (`/etc/soc/hook-mode` or a per-role override
  `/etc/soc/hook-mode-<role>`, default `audit`): always allows, but logs
  any out-of-manifest call to `permission-audit/<role>.log`
  (role-owned, `chattr +a` — a role can append its own audit trail but
  never rewrite/delete it).
- **Enforce mode**: denies anything not matching the manifest (still
  logged). Native `settings.json` `allow`/`deny` (compiled by
  `soc-build-settings`) is the primary boundary at this stage; the hook
  is redundant defense-in-depth.

**Recommended rollout per role**: start in `audit`, let real traffic run
for a few days, review `permission-audit/<role>.log` for legitimate
`AUDIT-NOMATCH`/`AUDIT-DENYMATCH` entries and add them to the manifest,
then flip to `enforce` (write `/etc/soc/hook-mode-<role>` and re-run
`soc-build-settings`; fully reversible, no drift — `soc-build-settings`
is a stateless, deterministic regeneration from the manifest + mode
file). This rollout is independent of cron — a role's timer runs on
schedule regardless of hook mode.

## 8. Escalation path for permission gaps

Two layers:

**Primary — the role itself.** Every role prompt's "Checking your own
permissions" section instructs: on an enforce-mode denial with no
allowed alternative, file a `permission_gap` ticket to `user` (via
`unassigned/` + `assigned_to: user`, `issuer: <role>`) naming the exact
denied command and its purpose, then give up on that path for the run —
no retries, no workarounds. The blocked work surfaces as a ticket the
human can act on, instead of silent audit-log lines.

**Backstop — `scripts/soc-escalate`** — deterministic, non-LLM, runs as
root (artifacts created as `soc-infra`). Diffs each role's
`permission-audit/<role>.log` against a checkpoint from its last run; on
new entries, files a `permission_gap` ticket directly to
`ticketing-system/user/` (`issuer: soc-infra`) and fires `soc-notify
low` (audit mode) or `soc-notify medium` (enforce mode — a real denial
happened in production). This catches denials the role didn't
self-report (framework-level calls the model never clearly saw, runs
that died before filing). It runs automatically from `soc-run-role`'s
post-run periodic-maintenance gate, at most once per 60 minutes,
alongside `heal-permissions --all` and `context-balloon-scan`; it also
files a separate `type: prompt_drift` ticket when one denial shape
repeats ≥3× in a batch (see `documentation/escalation.md`).

Either way the human reviews: add the pattern to the role's manifest
if legitimate, or leave it denied (itself a signal, potentially a
prompt-injection indicator).

## 9. Known gaps / things to harden further

1. **A cheap automated grep over `permission-audit/*.log` for recurring
   denials**, beyond what `soc-escalate`'s batch-level `prompt_drift`
   detection already catches, is a reasonable next step if you find
   yourself scanning those logs by hand often.
2. **A dedicated credential for unattended runs is strongly recommended
   over a shared OAuth token.** A shared `/etc/soc/oauth-token` means
   unattended cron runs and your own interactive sessions draw from the
   same usage window (manual role runs and interactive use can starve
   each other's quota), and an OAuth token goes stale whenever your own
   live session refreshes its token — a cron can't do that re-copy for
   you. A dedicated `ANTHROPIC_API_KEY` per role (the runner already
   prefers `/etc/soc/*.key` over the OAuth token, §5.1) avoids both
   problems.
3. **`hook-check`'s Bash matcher has no concept of shell control-flow
   syntax** (`for`/`do`/`done`, `while`, `if`/`then`/`fi`). `split_bash`
   splits a compound command into segments on shell separators, which is
   correct for pipelines/lists but treats a loop's header and body as
   opaque text segments too — a loop's body becomes a "subcommand" that
   must itself be allowlisted, and since the interpolated variable name
   and iteration list differ every time a role writes a loop, no allow
   pattern converges: tuning after one denial only ever matches that one
   past invocation, not the next superficially different one. This is
   likely to be your single largest source of recurring
   `permission_gap` tickets for any role whose job involves shell loops
   (e.g. a branch-status loop, or a per-source-type check). Fixing this
   requires reworking `bash_decision`/`split_bash` to recognize loop
   syntax structurally (validate the loop body's commands, not the
   loop's literal text) — a change to the matcher itself rather than an
   additive branch or manifest data; treat it with the same care as the
   rest of the security boundary.

## 10. Prompt-injection mitigations in place

Threat model: adversary-controlled log content reaching a role via
`siemctl` and steering it into unintended in-manifest behavior (the
permission manifest bounds *out-of-role* actions, not *in-manifest*
misuse — a log injection doesn't want `/etc/shadow`, it wants the
analyst to ack its own alerts or write a misleading ticket, both fully
in-manifest).

- **Instruction/data separation** in all four role prompts, covering
  both raw log/alert content and cross-role ticket bodies (a ticket's
  `Details` section can itself carry attacker-influenced text from an
  upstream role) — the primary defense, since the permission manifest
  and audit hook are both blind to a competent in-manifest injection.
- **`soc-restart-pipeline`** rate-limited + always-notifies on
  invocation (closes the "injection triggers a restart, which opens a
  brief ingestion gap" availability path).
- **`siemctl` PATH shim** fences `--data-dir` regardless of caller args
  (§5.2) — closes the "redirect siemctl's view to an attacker-chosen
  directory" gap.
- **`ticket-assign`** validates containment via canonicalized
  (`realpath`) paths, uses `mv -n` (no-clobber) and argv arrays (never a
  shell string), and rejects symlinked sources — closes TOCTOU/basename-
  injection/symlink-race gaps.
- **`ProtectHome=read-only`** restricts `/home`, `/root`, and
  `/run/user` — a role's actual `$HOME` (`/var/lib/soc/<role>`) sits
  outside all three, and is separately listed in `ReadWritePaths` (§5,
  `soc-run-role`'s `rw` array), so it's fully writable and persists
  across invocations by design (session transcripts, credential-refresh
  backups, and per-role memory all span many days). What this property
  actually buys is stopping a role from writing into the *operator's*
  home, not its own. The hook-config-tampering path via a role's own
  `$HOME/.claude` is genuinely open, not closed: it's gated only by
  `--bare` (§5.1), which suppresses `$HOME/.claude` discovery but
  requires an API-key credential in enforce mode — a role on a shared
  OAuth token never gets `--bare`. Nothing structural prevents an
  earlier compromised invocation from writing its own
  `$HOME/.claude/settings.json` and a later one picking it up. Worth
  closing before wider cron rollout (e.g. a dedicated API key per role,
  or explicitly re-deriving `$HOME/.claude/settings.json` from the
  manifest on every run the way `--settings` already does for the
  root-owned one).
- **tuner-dev's offline cargo** (`CARGO_NET_OFFLINE=true`, pre-vendored
  deps) — a ticket-influenced build can execute existing, human-reviewed
  dependency code (an accepted risk for a homelab-scale deployment) but
  can never fetch a new one.

**Not mitigated, by design:** a quiet `permission-audit` log is not
evidence a role is uncompromised — the audit hook only ever sees
out-of-manifest attempts.

## 11. Model scope

The permission manifests, `hook-check`, `ticket-assign`, the `siemctl`
shim, the sudoers rules, the filesystem hard layer, and the
`systemd-run` hardening profile are the actual security boundary of this
system. Treat any change to this set (a new elevated-privilege helper, a
change to the sandbox properties, a new sudoers grant) as worth an
adversarial self-review pass with your most capable available model
before shipping it — the standing rule this deployment was built under
is that the security boundary itself shouldn't be trusted to a single
routine-effort pass. Routine maintenance on top of an already-verified
boundary (operational plumbing, audit→enforce tuning, doc updates,
ticket-routing mechanism, ordinary bug fixes) doesn't need that same
level of scrutiny — reserve it for changes to the boundary itself.
