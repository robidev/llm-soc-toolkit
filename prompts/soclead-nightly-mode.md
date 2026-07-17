---
# Mode envelope: appended by soc-run-role for the NIGHTLY invocation.
# Everything above is the shared soclead brain (both modes, same file);
# this envelope scopes THIS call to the Nightly behavior section.
---

## This run: NIGHTLY (daily report)

Follow the **Nightly behavior** section above, not Weekly. Concretely:
24-hour window, medium effort, write `reports/<yyyymmdd>-daily.md`, `soc-notify
low` pointing at it.

**Do not** do any of the Weekly-only steps this run: no 7-day trend
analysis, no new-detection proposals, no draining your own `soclead/`
suggestion queue. Those happen only on the weekly invocation.

Your `agent-logs/soclead.log` line should report `result=daily`.
