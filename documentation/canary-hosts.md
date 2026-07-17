# Canary hosts (template — not agent context)

**This file is deliberately not readable by any SOC role.**
`soc-structure/provision/01-users-and-perms.sh` locks it `root:root 600`
at provisioning time — enforced at the OS level, not just by prompts
never being told to read it (see `soc-structure/runner-and-permissions.md`
§3).

If you run intentionally-vulnerable "canary"/honeypot hosts as a live
detection self-test (see `runbooks/environment.md`'s Canary section and
`soc-structure/overall.md`'s Cross-role rules), this is where to keep
anything about them that a role should never see even indirectly —
test-account credentials, exact vulnerable-service configuration,
anything an attacker (or a prompt-injected role) could use if it leaked.
The *fact* that a canary host exists, and how to recognize its alerts,
belongs in `runbooks/environment.md` instead (that file **is** agent
context) — only put things here that genuinely must never reach a role's
context window.

Ships empty in this toolkit. If you don't run canary hosts, delete this
file and drop its entry from
`soc-structure/provision/01-users-and-perms.sh`'s lockdown loop and
`scripts/soc-build-settings`'s `SAFETY_DENY` list — neither breaks if the
file is simply absent (`01-users-and-perms.sh` checks `[[ -f $f ]]`
first), but removing the references keeps things tidy.
