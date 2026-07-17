# CLAUDE.md

Guidance for Claude Code when working with this repository.

## Querying the SIEM

When you need to search events, check alerts, or investigate logs:

**Use the `/siemctl` skill** (in the sibling `headless-siem` repo) — it has full documentation, common query patterns, and indexed-field references. Key commands:

- `siemctl search --query "..."` — query indexed fields with a SQL-ish DSL
- `siemctl stats --after <ISO8601>` — event counts and coverage
- `siemctl search --raw 'substring'` — bypass the index, search raw logs
- `siemctl tail --follow` — stream logs as they arrive

**Common SOC queries** are documented in the skill, e.g.:
- Check for external access: filter `src_ip` outside your CIDR ranges
- Find all errors/warnings: `severity == 'error' OR severity == 'warning'`
- Group by source: `SELECT src_ip, count GROUP BY src_ip`

**Indexed fields per source** are listed in the skill's reference section — this tells you which fields you can filter on. If a field isn't indexed, use `raw_contains('needle')` instead.

For full flag reference and DSL grammar, see: `../headless-siem/.claude/skills/siemctl/SKILL.md`

## Operating the SOC by hand

For tickets, running a role manually, restarting the pipeline, deploying a fix,
or any other hands-on maintenance action: **see `.claude/skills/soc-tools/SKILL.md`**
— a command reference for exactly this. (Not auto-loaded for the four sandboxed
SOC roles — their manifests deny the `Skill` tool — this is for you, the operator.)

## Role memory

Each of the four sandboxed roles (analyst, soclead, specialist, tuner-dev)
has its own persistent auto-memory, scoped to its own Unix account —
`/var/lib/soc/<role>/.claude/projects/<mangled-cwd>/memory/MEMORY.md`
(sudo required to read). Not shared across roles. Details, including why
it persists under the sandbox: `soc-structure/runner-and-permissions.md`
§5.1 ("Persistent memory").

## Documentation References

- **Runbooks** (`runbooks/` — repo root, not under documentation/) — per-source triage guidance (filterlog, sshd, haproxy, ...) plus the environment cheat-sheet. Ship as templates — rewrite from your own traffic baseline before relying on them.
- **Operator manuals** (`documentation/`) — deployment-guide.md, ticket-handling.md, tuner-dev-branch-merge.md, running-roles-manually.md
- **SOC structure** (`soc-structure/`) — overall.md (role spec), runner-and-permissions.md (sandbox/permission architecture), manifests/ (the actual per-role permission files)
- **Ticketing format spec** (`ticketing-system/system.md`) — frontmatter fields, filename rules, who may close what type
- **User escalation** (`documentation/escalation.md`) — notification channel spec
- **Your network reference** (`soc_context/`) — network topology, firewall policy, IP/VLAN/host inventory, and SIEM baseline snapshots. Ground-truth material an investigation draws on, kept separate from the SOC-process docs above. Ships as empty templates — author your own, per the deployment guide's step 2. `soc_context/architecture.md` indexes the folder's own contents in more detail.

## Keeping secrets out of agent context

Any file with real credentials or ground-truth an LLM role should never
see (test-host credentials, an unsanitized firewall config export) should
be locked `root:root 600` outside every role's read path — see
`soc-structure/runner-and-permissions.md` §3 and
`documentation/canary-hosts.md` for the pattern this toolkit uses.
`CLAUDE.md` files (this one, and any parent-directory one above this
repo) should stay `user:user 640`, unreadable by any `socroles` member —
same section explains why.
