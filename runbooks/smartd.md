# smartd runbook

*Template: this is a starting shape based on a real deployment's runbook. The per-host temperature/counter ranges below are illustrative examples, not real telemetry — replace with your own hosts' observed baselines.*

Source: `smartd` — disk SMART-attribute-change telemetry (smartmontools'
`smartd` daemon), typically forwarded from any host you run it on (device
paths like `/dev/sda [SAT]`). Check whether your SIEM's source config has
a dedicated `index_fields` entry for `smartd` — if not, it likely falls
through to a generic default field set that `smartd` doesn't populate, in
which case the actual signal is entirely in the unindexed `message`
field. Query with a `SELECT ... message ...` projection or
`raw_contains(...)`, not a `WHERE`-clause field filter, in that case.

## What normal looks like

Once you have a few days of real data, expect every event to be a
routine SMART Usage Attribute value change, typically dominated by one or
two attributes:

- **Attribute 194, `Temperature_Celsius`** — usually the overwhelming
  majority of events. Fluctuates slowly through the day, one-degree
  steps. Example per-host ranges (illustrative only — replace with your
  own): `node-a` 34-42C, `node-b` 33-41C, `node-c` 28-38C. Different
  hosts run at different baseline temperatures depending on hardware and
  placement; judge each host against its own recent range, not a single
  global number.
- **Attribute 195, `Hardware_ECC_Recovered`** — often a smaller share of
  events, a small incrementing counter. This is the drive's
  error-correction-recovery counter increasing during normal read
  activity — routine at a low, steady rate of change, not a drive-health
  signal on its own.

Events are typically shaped like:
`Device: /dev/sda [SAT], SMART Usage Attribute: <id> <name> changed from
<old> to <new>`. If no reallocated-sector, pending-sector, or overall-
health attributes have appeared in your production data yet, that's
expected for healthy drives — don't assume they can't occur.

## Escalation criteria

- **`noise`/no ticket needed:** `Temperature_Celsius` or
  `Hardware_ECC_Recovered` changes within/near the host's established
  range, one attribute-step at a time.
- **`incident` to specialist (at least medium):** any of the following —
  treat any occurrence as first-of-kind and worth real scrutiny until
  you've built a baseline for it —
  - `Reallocated_Sector_Ct` or `Current_Pending_Sector` /
    `Pending_Sector` increasing (physical sector failures accumulating)
  - a SMART overall-health self-assessment result of `FAILED`
  - `Temperature_Celsius` jumping well outside the host's established
    range from "What normal looks like" above, or climbing steadily
    rather than fluctuating
  - a new device path (anything other than your known devices) or a host
    not previously seen as a `smartd` source appearing for the first time
    — could be legitimate (new disk/host onboarding) but confirm before
    closing as benign, same treatment as any new-source digest flag

## Canned queries

```bash
siemctl search --query "SELECT timestamp,hostname,message WHERE _source_type == smartd" --after <window-start>
siemctl search --raw 'Reallocated_Sector' --after <window-start>
siemctl search --raw 'FAILED' --after <window-start>
```

## Provenance

Drafted from real production data and re-verified against fresh activity
before writing this template — the specifics above have since been
genericized for publication, so treat the illustrative per-host ranges as
a format example, not real numbers to compare against. Draft your own
version interactively with a human reviewer rather than authoring
escalation criteria unsupervised — the failure-mode bullets above are
inferred from standard SMART semantics, not necessarily exercised against
a real degraded-disk event; review before leaning on them for an actual
alert.
