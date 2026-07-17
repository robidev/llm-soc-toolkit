# IP plan (template)

**This file ships empty/illustrative — author your own.** Full subnet/
VLAN/host/VM inventory: what's on each network segment, which IPs are
infrastructure vs. workstations vs. DMZ/test hosts. This is the
authoritative source `architecture.md` and `../runbooks/environment.md`
should be distilled from — write this one first.

## Subnets

| Subnet | Purpose | DHCP range | Notes |
|---|---|---|---|
| 10.0.0.0/24 | (example) untagged/OOB | .10-.50 | replace with your own |

## Hosts

| Hostname | IP | Role | Notes |
|---|---|---|---|
| (example) your-siem-host | 10.0.20.11 | Runs headless-siem + this toolkit | |

## VM/hypervisor inventory

If you run a hypervisor cluster, list nodes and notable guests here (or
point at `cmdb/` if you export this automatically). Flag anything you
can't currently identify — that's what `open-questions.md` is for, don't
let an unconfirmed guess quietly become "documented fact" in this table.

## Remote access (VPN, if any)

Document tunnel subnet, routes pushed, auth method, and current
enabled/disabled status. If disabled, keep the config documented here for
when it's re-enabled, but never leave a real static key/credential in a
file any SOC role can read — see `architecture.md`'s note on keeping
unsanitized secrets outside every role's read path.
