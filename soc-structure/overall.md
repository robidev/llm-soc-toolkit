# SOC structure — role specification

Single authoritative spec for the LLM-driven SOC.

Every role reads/writes tickets per `../ticketing-system/system.md`. Every
role appends one line per run to `../agent-logs/` (format: see
`ticketing-system/system.md` § agent logs).

Pin model IDs in your own cron configs so they're unambiguous and survive
model releases (e.g. a Haiku model for the analyst's cheap classification
pass, a Sonnet-class model for everything else). Whether a higher-end
model (e.g. Opus) is worth the cost for any role is a call to make against
your own traffic and budget — this spec doesn't mandate one.

---

## analyst

- **Trigger:** cron, on a short interval (e.g. every 10–60 minutes —
  tighter catches things sooner but costs more; pick what your budget and
  traffic volume support).
- **Model / effort:** a cheap/fast model, LOW effort for the
  classification pass. If the run continues into triage (see below), a
  **second invocation** runs a more capable model, MEDIUM effort for the
  triage portion — implemented as two separate `claude` calls chained by
  `soc-run-role`, not one self-escalating session (see
  `runner-and-permissions.md` §5.4 for the two-pass contract).
- **Inputs:**
  - `siemctl digest --window <N> --format json` (machine-readable) and the
    text form (for the triage narrative)
  - `siemctl alerts --after <timestamp of this role's previous run>`
    (timestamp read from this role's last `agent-logs/` line, **with the
    lookback capped** — an uncapped `--after` from a stale watermark can
    dump megabytes into context; see `prompts/analyst.md`'s Inputs section
    for the capped recipe)
  - this role's own previous run's `agent-logs/` line, for continuity
  - `../runbooks/environment.md` (always loaded — small, cheap)
  - the relevant per-source runbook section only, loaded *if* triage is
    needed and only for the source(s) implicated (not the whole runbook set)
- **Allowed tools (prompt-injection defense — digest/alert content is
  attacker-controlled input):** read-only `siemctl` subcommands,
  ticket-file writes under `ticketing-system/analyst/` and
  `ticketing-system/unassigned/`, append to `agent-logs/`, and the
  `soc-notify` script (see `../documentation/escalation.md`) for
  high/critical only. No general shell, no file writes outside those
  paths, no editing SIEM config.
- **Behavior:**
  1. Classify the digest: is anything flagged (volume spike, new source,
     new destination, first-time alert rule) above the all-clear threshold?
     If not, log `result=clear` and exit. This should be the common case.
  2. If yes, triage using the loaded runbook section: is it a known-benign
     pattern? If so, close it — `siemctl alerts ack --note <reason>` where
     applicable — and log `result=triaged verdict=benign`.
  3. If not resolvable as benign, file a ticket. Use the type → route table
     in `../ticketing-system/system.md` § routing. The default type for
     "this looks like real suspicious activity" is `incident`, assigned to
     `specialist`. Priority follows the digest's own severity signal, with
     one override: **correlated alerts carry no `level` field** (SIEM data
     model gap, not a bug) — treat any correlated alert as **at least
     medium** priority until a human or the specialist triages it further.
  4. If priority is **high or critical**: do both of — file the incident
     ticket to `specialist`, AND fire `soc-notify high|critical <subject>
     <body-file>` directly, rather than waiting for the next specialist
     cron tick — this closes the latency gap between now and that role's
     next scheduled run.
  5. Non-incident follow-ups, filed regardless of step 1-4's outcome:
     - tool bugs → `bug` ticket to `tuner-dev`
     - feature gaps → `feature` ticket to `tuner-dev`
     - suspected false positive / noise → `noise` ticket to `tuner-dev`
     - unparseable/garbled source → `parsing_error` ticket to `tuner-dev`
     - a source that should be logging but isn't → `missing_logs` ticket to
       `user`
  6. Always log a structured `agent-logs/` line, even on `result=clear`.
- **Never:** touches `config/rules/suppress.toml` or any SIEM config
  directly — see the feedback-loop note below.

---

## specialist

- **Trigger:** cron, hourly (or your own interval — event-driven early
  runs aren't required; the analyst's direct notification already covers
  the latency-sensitive case).
- **Model / effort:** a capable model, HIGH effort.
- **Inputs:** full read-only `siemctl` query access (not just digest/alerts
  — `search`, `stats`, entity timelines), all runbooks relevant to the
  ticket(s) being drained, `../runbooks/environment.md`, the CMDB export
  if you maintain one.
- **Allowed tools:** read-only `siemctl` (full command surface), ticket-file
  read/write under `ticketing-system/specialist/`, append to `agent-logs/`,
  `soc-notify` for user escalation.
- **Behavior:** drain all open tickets assigned to `specialist`. Per ticket:
  investigate with follow-up `siemctl` queries until confident, then either:
  - **close** — append findings as a comment, set `Status: closed`, rename
    `CLOSED_...` (see ticket spec); or
  - **escalate to user** — fire `soc-notify` with a findings summary, leave
    the ticket `Status: in_progress` (not closed — a human is now the next
    actor).
  May also file, to other roles:
  - `bug` / `feature` tickets → `tuner-dev`
  - `noise` / `tuning` / `parsing_error` tickets → `tuner-dev` (this is the
    FP-verdict feedback loop — see below)
  - `suggestion` tickets (new detection ideas, coverage gaps noticed while
    investigating) → `soclead`

---

## tuner-dev

- **Trigger:** cron, every few hours (a longer cadence than analyst/
  specialist — its work is tuning/fixing, not time-sensitive triage).
- **Model / effort:** a capable model, HIGH effort.
- **Inputs:** all open tickets in `ticketing-system/tuner-dev/`, current
  `config/rules/suppress.toml`, `config/normalized.toml`, relevant Sigma
  rules, `siemctl` (read-only, for verifying a fix against real data before
  proposing it).
- **Allowed tools:** everything `specialist` has, plus **git-branch-scoped**
  write access to the SIEM's `config/` and small `siemctl`/detection-engine
  bug fixes. **This is the only role with any write access to SIEM
  configuration or code.**
- **The feedback loop, ownership stated explicitly:** an analyst or
  specialist FP verdict becomes a `noise`/`tuning` ticket to `tuner-dev`.
  tuner-dev edits `config/rules/suppress.toml` — every new suppression rule
  **should** carry an `expires` date, so stale suppressions get revisited
  instead of accumulating forever — or `config/normalized.toml`, or a
  Sigma rule. **Nobody else touches `suppress.toml`.**
- **Guardrail (non-negotiable):** tuner-dev commits its change to a git
  branch (in a git-tracked clone of the SIEM repo) and files a
  `user`-assigned review ticket linking the branch/diff. **It does not
  merge or deploy.** A bad suppression rule can silently kill detections —
  a human merges and restarts services. Loosen this only after a
  demonstrated track record.
- **Behavior:** prioritize open tickets to fit the role's own token budget
  each run (cheapest/most-impactful first is a reasonable heuristic); carry
  the rest to the next run. Ticket types handled: `bug` (fix), `feature`
  (implement if small; otherwise file as a scoped ticket back rather than
  guessing), `noise`/`tuning` (suppress.toml edit), `parsing_error`
  (normalized.toml override/extract rule, or new parser if the format is
  genuinely new). `missing_logs` tickets tuner-dev cannot itself resolve
  (it's a forwarding/config problem, not a SIEM-code problem) — reassign to
  `user`.

---

## soclead

- **Trigger:** cron, nightly (daily report) and weekly (trend report — same
  role, different window and effort).
- **Model / effort:** a capable model, MEDIUM effort nightly; HIGH effort
  weekly.
- **Nightly behavior:** aggregate `agent-logs/` entries and
  tickets opened/closed over the last 24h into a daily report doc for the
  user (a plain doc drop into `reports/`, not a ticket — see the delivery
  note below). File `suggestion`/`bug` tickets to `tuner-dev` for
  anything systemic noticed (e.g. one source generating a
  disproportionate share of noise tickets).
- **Weekly behavior:** same aggregation over 7 days plus trend analysis —
  are `noise`/`tuning` tickets declining over time? Is suppression coverage
  (count of active, non-expired `suppress.toml` rules) growing in step with
  noise sources? Propose new detections as tickets to `tuner-dev`.
- **Inputs:** `agent-logs/`, all ticket folders (read-only outside its own),
  `config/rules/suppress.toml` (read-only, for the coverage-growth check).
- **Allowed tools:** read-only across the whole ticket tree and
  `agent-logs/`, write only within its own report output location and
  tickets it files to `tuner-dev`.
- **Note on report delivery:** the nightly/weekly report is a doc, not a
  ticket (nothing to route or close) — write it to
  `reports/<yyyymmdd>-daily.md` (or `-weekly.md`), and fire a
  low-priority `soc-notify` pointing at it so the user knows it landed.

---

## Cross-role rules

- **Concurrency/ownership:** see `../ticketing-system/system.md` §
  concurrency — only a ticket's current assignee may edit or move it.
- **Canary-host alerts:** if you run intentionally-vulnerable "canary" or
  honeypot hosts as a live detection self-test (optional — see
  `../runbooks/environment.md`), any role handling a canary-related alert
  marks `[CANARY]` in the ticket subject and **never auto-closes as
  benign** — a canary alert firing is the detection self-test working;
  closing it silently would hide a broken detection instead. Still
  triage/investigate normally otherwise.
- **Escalation channel:** all roles that notify the user use the single
  `soc-notify` wrapper — see `../documentation/escalation.md` for the exact
  command, per-role/per-priority permissions, and rate limits.
