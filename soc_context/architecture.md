# Architecture — your network (template)

**This file ships empty/illustrative — author your own.** See the
deployment guide's step 2. This is the "what's actually on my network"
ground truth an investigation draws on — none of it is code, and none of
it should be copied from another deployment (including this template's
own placeholder values). For the SOC-facing "what's normal" summary
distilled from this data, see `../runbooks/environment.md`.

## Network topology

Sketch your own topology here — a plain diagram is enough, it doesn't
need to be fancy. Example shape (replace entirely with your own):

```
                              internet
                                 │
                            (your WAN)
                                 │
                    your gateway/firewall
                                 │
        ┌────────────────────────┴─────────────────────────┐
        │ LAN 10.0.0.0/24                     other segments...
        │
   ┌────┴──────────────────────┐
   │                            │
your firewall/router      other infra (NAS, switch, ...)
```

If you run VLANs, a table like this is useful:

| VLAN | Purpose | Subnet | Notable hosts |
|---|---|---|---|
| (e.g. 10) | Management | 10.0.10.0/24 | ... |
| (e.g. 20) | Servers | 10.0.20.0/24 | your SIEM host, ... |
| (e.g. 30) | IoT/guest | 10.0.30.0/24 | (out of SIEM scope, or not) |

## Firewall policy summary

Describe your default posture per interface/segment (default-allow-
outbound vs. default-deny, which segments can reach which) and any
interfaces that deviate from the default. If you keep a firewall config
export, point this section at it (redact secrets/keys/hashes first if an
LLM role or anyone outside your trust boundary will ever read the
export — see the note on `canary-hosts.md`-style lockdown below for how
this toolkit keeps genuinely sensitive files out of agent context
entirely).

## Logging posture

If you've tuned down what your firewall/gateway logs (a common need —
default "log everything the rules say to log" can be very high-volume,
low-value), note what changed and why here, so a future investigation
isn't confused by an apparent drop in coverage that was actually a
deliberate tuning decision.

## Reference documents in this folder

| Document | Contents |
|---|---|
| `architecture.md` | this document |
| `ip_plan.md` | full IP/VLAN/host/VM inventory |
| `open-questions.md` | gaps and follow-ups found while writing these docs, not yet resolved |
| `cmdb/` | optional — a host/VM inventory export (e.g. from a hypervisor), if you maintain one |
| `log-forwarding-setup.md` | device-by-device instructions for getting your own infrastructure forwarding logs to the SIEM |
| `baselines/` | daily `siemctl digest` snapshots, captured automatically by `scripts/capture-baseline` once logs are flowing — don't hand-write these |

If you keep a sanitized firewall/gateway config export here for agent
reference, keep an **unsanitized** copy (if you need one at all) outside
this folder and outside any role's read path entirely — see
`soc-structure/runner-and-permissions.md` §3 for the pattern this
toolkit uses to lock down files like that at the OS level, not just by
prompt instruction.
