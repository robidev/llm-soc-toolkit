# Environment — always-loaded cheat sheet (template)

**This file is loaded on every analyst run — keep it small and cheap.**
It's the SOC's "what does normal look like here" summary, distilled from
`soc_context/ip_plan.md` and `soc_context/architecture.md`. Rewrite it
once those reflect your own network; this template ships with
placeholder content only.

## Network topology (summary)

Keep this short — the full detail lives in `soc_context/ip_plan.md`.
Just enough here for a role to sanity-check "is this source/destination
somewhere I'd expect":

| Segment | Subnet | Notes |
|---|---|---|
| (example) LAN | 10.0.0.0/24 | replace with your own |
| (example) Servers | 10.0.20.0/24 | your SIEM host lives here |

## What normal traffic looks like

Summarize the shape of your own baseline once you have a few days of
`siemctl digest` history (`soc_context/baselines/` — captured
automatically by `scripts/capture-baseline`, don't hand-write these):
typical event volume per hour, which sources are chatty vs. quiet, which
hosts talk to which segments routinely.

## Canary hosts (optional)

If you run intentionally-vulnerable "canary" or honeypot hosts as a live
detection self-test (a real, useful pattern — any role handling a
canary-related alert should mark `[CANARY]` in the ticket subject and
**never auto-close it as benign**, since a canary alert firing is the
detection working, not noise), document them here: hostnames/IPs, what
attack surface they intentionally expose, and what a "detection working
correctly" alert looks like for each. Delete this section entirely if
you don't run any.

## Standing exceptions

Anything else every role should know without re-deriving it each run —
e.g. a host that's expected to generate certain alerts by design, a
maintenance window pattern that's routinely noisy and already understood.
Keep this list short; it's meant for genuinely recurring, already-settled
judgment calls, not a dumping ground for every past incident.

## Known documentation gaps

Track anything you haven't fully nailed down yet here (or just point at
`soc_context/open-questions.md` if you're tracking it there instead) —
an unidentified subnet, a host whose purpose is unclear. Better to flag
a gap explicitly than let a role's context imply more confidence than
the docs actually have.
