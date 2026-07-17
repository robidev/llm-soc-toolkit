# Per-role permission manifests

`manifest-enforced-<role>.json` is the source of truth for each role's
`permissions` allow/deny list — derived from each role's own prompt
"Allowed tools" section (see `runner-and-permissions.md` §6), checked
against the live Claude Code permission docs
(`code.claude.com/docs/en/permissions.md`). Each
file is a partial `settings.json`: `soc-build-settings` merges its
`permissions` block into `/etc/soc/<role>-settings.json` for native
enforcement, and the PreToolUse hook (`scripts/hook-check`) reads the
same `allow`/`deny` arrays independently to decide/log (see
`runner-and-permissions.md` §7 for audit-vs-enforce mode and how to
check or flip a role's mode).

**Read the JSON, not this file, for the enforced truth** — prose
transcriptions of the pattern lists have drifted out of sync with what's
actually deployed before.

## Design rules these manifests follow

1. **No bare `Bash` deny.** Precedence is deny → ask → allow, first
   match wins, and a *bare* tool-name deny removes the tool from context
   entirely. `deny: ["Bash"]` would kill the role's own allowed
   `siemctl`/`sudo` commands. "No general shell" is instead enforced by
   the allowlist being exhaustive plus the PreToolUse hook's default-deny,
   not a bare deny.
2. **No bare `Edit` deny.** "Edit rules apply to all built-in tools that
   edit files" — i.e. the Edit family includes `Write`. A bare `Edit`
   deny would kill each role's ticket `Write(...)`. Roles that shouldn't
   edit source simply have no `Edit(...)` allow, so Edit is denied by
   default (hook / dontAsk); tuner-dev keeps scoped `Edit(...)` allows
   for its worktree.
3. **Path anchoring.** A leading-slash `/path` anchors at the
   `--settings` file's directory (`/etc/soc/`), and `../runbooks` escapes
   the tree. All in-tree paths are therefore **cwd-relative with no
   leading slash** (`Read(runbooks/**)`, `Write(ticketing-system/analyst/**)`),
   which anchors at the current directory. **These manifests assume the
   role's cwd is `/home/user/projects/llm-soc-toolkit`** (the documented
   working dir; set by the runner). Out-of-tree paths (headless-siem, the
   tuner-dev worktree) use `//` absolute anchors.
4. **siemctl:** per-subcommand prefix allows (`Bash(siemctl digest *)`).
   The `--data-dir` redirect risk (§11.2(2)) is handled by the `siemctl`
   PATH shim, **not** by trying to constrain args in the pattern — the
   docs explicitly warn that arg-constraining Bash patterns are fragile.
5. **Scoped denies** act as belt-and-suspenders (they block a matching
   call without removing the tool): `siemctl retention/dry-run/validate`,
   `systemctl`, the per-role `soc-notify` priority ceilings, and
   `documentation/canary-hosts.md` (also OS-blocked at root:root 600).

## Absolute paths baked in (grep targets for a future relocation)

These files hardcode `/home/user/projects/llm-soc-toolkit/...` (helper
scripts) and are grep-findable via the `[SOC-ROOT-PATH]` tag. `/var/lib/soc/...`
(tuner worktree) and `/home/user/projects/headless-siem/...` do **not**
change if the tree relocates. `/usr/local/bin/ticket-assign` is fixed.

## Current status

These manifests are the ones actually shipped, in **enforce** mode
(matching the deployment guide's recommended end state after the
audit-mode soak period). `cat /etc/soc/hook-mode-<role>` to confirm a
given role's mode once deployed; see `runner-and-permissions.md` §7 to
flip one back to `audit` if a manifest gap needs tuning against your own
environment.

Expect to add allow entries of your own as you run against real traffic
— a common source of these is shell loop syntax (`for`/`do`/`done`),
which `hook-check`'s Bash matcher treats as opaque per-invocation text
rather than structurally (see `runner-and-permissions.md` §9, item 3)
and a role's own idioms (e.g. an exact-match timestamp command, a
`sed -n` invocation) that weren't anticipated when these manifests were
written. Each manifest's own `_meta` block (where present) documents
why a given entry exists.
