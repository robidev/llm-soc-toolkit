---
# Mode envelope: appended by soc-run-role for the WEEKLY invocation.
# Everything above is the shared soclead brain (both modes, same file);
# this envelope scopes THIS call to the Weekly behavior section.
---

## This run: WEEKLY (trend report)

Follow the **Weekly behavior** section above, not Nightly. Concretely:
7-day window, high effort, the trend analysis (noise/tuning decline,
suppression-coverage growth), the layer-3 agent-behavior review
(`agent-logs/transcript-digest-weekly.md`), new-detection proposals,
and the suggestion-queue drain — then write
`reports/<yyyymmdd>-weekly.md`, `soc-notify low` pointing at it.

This still includes everything the Nightly section covers (agent-logs
aggregation, ticket aggregation, the stale-ticket scan) — Weekly is a
superset over a longer window, not a replacement pass.

Your `agent-logs/soclead.log` line should report `result=weekly`.
