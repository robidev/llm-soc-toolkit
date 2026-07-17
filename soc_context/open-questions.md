# Open questions

A running list of network facts you haven't confirmed yet while writing
`ip_plan.md`/`architecture.md` — an IP you can't identify, a VLAN whose
purpose is unclear, a host in a CMDB export with no obvious owner. Keeps
unverified guesses out of the ground-truth docs instead of silently
treating them as confirmed; move an item here into the real doc once
you've actually confirmed it, don't just guess in place.

This file ships empty — there's nothing to track until you start writing
the docs above against your own network.

## Example shape

1. **What is `10.0.30.0/24` for?** No documented hosts, but a DHCP scope
   is configured — something is expected to live here.
2. **Is the wide-open rule on interface X intentional**, or a leftover
   from initial setup that should be tightened?
