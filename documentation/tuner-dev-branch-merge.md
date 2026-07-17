# Merging a tuner-dev fix branch — a human's guide

`tuner-dev` produces fix branches (suppression rules, parser fixes,
retry-logic changes, etc.) in `headless-siem`, but **can never push,
fetch, or merge them itself** — its manifest deliberately excludes `git
push`/`fetch`/`remote` to avoid a git-based egress path
(`soc-structure/manifests/manifest-enforced-tuner-dev.json`'s own
comment: "git enumerated (no fetch/remote/push) to avoid a git-based
egress path"). Its branches stay local to its isolated worktree
(`/var/lib/soc/tunerdev/headless-siem`) until a human pulls them out,
reviews, and merges. That's this document.

**`scripts/tuner-review <ticket-path>`** automates steps 1, 2, 4, 5, 6,
and 8 below (fetch, diff, merge, push, deploy, close) — see `.claude/
skills/soc-tools/SKILL.md`. You still do step 3 (test) and step 7
(verify live) yourself; the script gates on cargo test passing and
prompts you for a live-verification note before it'll close the ticket.
Read this doc once regardless, since the script assumes you understand
what each automated step is actually doing.

Every step below reflects a workflow that's been walked through live for
a real tuner-dev fix branch (a suppression-rule change is a typical
example) — this isn't a hypothetical process.

## 0. Find the review ticket

Tuner-dev files a `type: tuning` (or `bug`/`feature`) review ticket to
`user/` when it finishes a branch — `sudo scripts/soc-ticket list --role
user` or just look in `ticketing-system/user/`. The ticket names the
branch and summarizes what changed, what was verified, and how (tuner-dev
runs its own tests before ever filing the ticket — read that section, it
tells you what's *already* been checked so you're not duplicating work).

## 1. Pull the branch into the main repo

The branch only exists in the isolated worktree. From
`/home/user/projects/headless-siem` (your normal working copy):

```bash
sudo git fetch /var/lib/soc/tunerdev/headless-siem <branch-name>:<branch-name>
```

(`sudo` because the worktree directory is root/soc-tunerdev-owned, not
readable as your own user.) This creates a local branch in your repo
without touching origin/GitHub yet.

## 2. Review the diff

```bash
git log --oneline master..<branch-name>
git diff master <branch-name>
```

Sanity-check against the review ticket's own description: does the diff
match what it says? Is it scoped to exactly the file(s) it should touch?
For a suppression rule specifically, check the `condition` is as narrow
as it claims (tuner-dev's ticket should already show this, e.g. a
`cidr_match` range that doesn't overlap anything else) — you're
double-checking, not re-deriving the analysis from scratch.

## 3. Test

```bash
cd /home/user/projects/headless-siem
cargo test -p <affected-crate>     # e.g. -p ruled, -p siemctl, -p indexd
```

Tuner-dev already ran this before filing (should be `N/N` in the ticket)
— re-running it yourself just confirms the branch you actually fetched
matches what was tested, not a stale/different copy.

**If the change should be exercised through `tests/detections/run-all.sh`**
(a new/changed detection rule, a suppression rule, anything the
detection-test harness covers): that script drives `dev.sh`'s **local
dev pipeline**, which is separate from the production systemd services
but **defaults to the same UDP port (5514)** production's `normalized`
already listens on. Always override it:

```bash
SIEM_PORT=15514 ./dev.sh build
SIEM_PORT=15514 ./dev.sh start
SIEM_PORT=15514 ./tests/detections/run-all.sh
SIEM_PORT=15514 ./dev.sh stop
rm -rf data/          # dev.sh's own data dir, safe to wipe, isolated from production
```

(`dev.sh`'s data dir defaults to `<repo>/data/`, already separate from
production's `/var/lib/headless-siem` — only the port needs the manual
override.)

**Important limitation**: `dev.sh`'s `start_ruled()` never passes
`--suppress`, so `run-all.sh` passing does **not** prove a new
suppression rule actually suppresses anything — it only proves nothing
*else* regressed. If the change is a suppression rule, verify it
directly:

```bash
# find the ruled pid dev.sh started, and its pipe paths
PIPE_DIR=/tmp/headless-siem-dev
RULED_PID=$(cat "$PIPE_DIR/ruled.pid")

# hold the input pipe open so normalized doesn't SIGPIPE while ruled is down
exec 9<> "$PIPE_DIR/normalized-out.pipe"
exec 10<> "$PIPE_DIR/ruled-out.pipe"
kill "$RULED_PID"; sleep 1

./target/debug/ruled --rules config/rules --output data/alerts \
  --dedup-window 5 --suppress config/rules/suppress.toml \
  < "$PIPE_DIR/normalized-out.pipe" > "$PIPE_DIR/ruled-out.pipe" \
  2>"$PIPE_DIR/logs/ruled-suppress-test.log" &
NEWPID=$!
exec 9>&- 10>&-

# inject the in-range case (should NOT alert) and a control case (should)
echo '<line matching the suppressed condition>' > /dev/udp/127.0.0.1/15514
echo '<same rule, different/control value>'     > /dev/udp/127.0.0.1/15514
sleep 3
grep -r '"src_ip"' data/alerts/2026/*/*/*/alerts.jsonl   # confirm: suppressed case absent, control present

kill -9 "$NEWPID"    # this process bypasses dev.sh's own pid tracking —
                      # `./dev.sh stop` will NOT catch it; kill it yourself,
                      # plain `kill` may not take (blocked on the torn-down
                      # pipe), use -9 and confirm with `ps` afterward
```

## 4. Merge

```bash
cd /home/user/projects/headless-siem
git checkout master
git merge --no-ff <branch-name> -m "Merge <branch-name>: <one-line summary>

Reviewed via <path to the review ticket>.
<why this is safe to merge — what was verified, by whom>"
```

`--no-ff` keeps the fix as an identifiable merge commit rather than
folding invisibly into master's linear history — makes it easy to spot
"which changes came from a reviewed tuner-dev branch" later.

## 5. Push

```bash
git push origin master
```

## 6. Redeploy to production

**Merged is not deployed.** Two things can be out of sync with what's
actually running:

- **Binaries**: if the change touched any Rust source (not just a
  `.toml`/`.yml` config), the installed binary at `/usr/local/bin/<name>`
  is a separate build artifact. Use `scripts/redeploy-binary` rather than
  a hand-rolled `cargo build`/`install` — it also stamps the deployed
  commit so `scripts/check-deploy-drift` (see below) can tell this deploy
  apart from a stale one later:
  ```bash
  sudo scripts/redeploy-binary <crate>            # e.g. ruled, siemctl, indexd
  # add --restart to also restart the matching systemd unit in one step;
  # without it, the new binary is on disk but the running process keeps
  # using the OLD one until you restart it yourself (see below)
  ```
  (siemctl has no running process to restart — `--restart` is a no-op for
  it, safe either way.)
- **Config files**: production units often read from `/etc/headless-siem/`
  or `/etc/soc/`, **not** the repo path directly — always check first:
  ```bash
  systemctl cat headless-siem-<unit> | grep -A2 ExecStart
  ```
  If it points at `/etc/headless-siem/...`, that's a separate file the
  repo's copy has to be manually pushed to:
  ```bash
  diff /etc/headless-siem/<path> /home/user/projects/headless-siem/config/<path>
  sudo cp /home/user/projects/headless-siem/config/<path> /etc/headless-siem/<path>
  ```

**Restart only the unit(s) that actually need the new file/binary.**
Restarting `ruled` (or `normalized`, or `indexd`) is safe even though
each is piped into the next — every downstream unit's `.service` file has
`Restart=always` specifically because an upstream restart EOFs its input
pipe and that's a *clean* exit, not a failure (`on-failure` wouldn't
catch it — this is documented in the unit files themselves). Confirm the cascade recovered:

```bash
sudo systemctl restart headless-siem-<unit>
sleep 3
systemctl is-active headless-siem-normalized headless-siem-indexd \
  headless-siem-ruled headless-siem-correlated headless-siem-alert-watch
sudo journalctl -u headless-siem-<downstream-unit> --since "2 minutes ago" --no-pager
```
A downstream unit briefly showing `activating` right after is expected,
not a problem — give it the `RestartSec` window (5s by default) before
worrying.

**Confirm the deploy actually landed:**

```bash
sudo scripts/check-deploy-drift
```

Exit 0 means every binary's deployed commit matches the latest commit
that touched its crate, and every systemd-managed binary's running
process matches what's on disk. A nonzero exit here means either you
forgot `redeploy-binary` for one of the touched crates, or you deployed
the binary but never restarted the service — both are called out by
name in the output, no need to guess. This doesn't replace step 7's
functional verification below; it only confirms the *mechanics* of the
deploy (right code, actually running), not that the fix behaves
correctly.

## 7. Verify live

Re-run whatever the review ticket's own verification was, against real
production data:

```bash
siemctl search --query "..."     # confirm the underlying event still gets indexed (no data loss)
siemctl alerts --window <N>m     # confirm the expected behavior change (e.g. no new alert, for a suppression)
sudo journalctl -u headless-siem-ruled --since "5 minutes ago" | grep -i "loaded"  # config actually picked up
```

## 8. Close the review ticket

```bash
sudo scripts/soc-ticket close <path-to-review-ticket> "Reviewed and merged <date>. <summary: diff matched the ticket, tests X/Y passed, deployed via <steps>, verified live via <query/result>.>"
```

Write enough in the closing comment that a future reader doesn't have to
reconstruct the deploy/verification trail from git log alone — this
comment is the audit trail.

## 9. Housekeeping (optional but tidy)

```bash
git branch --merged master | grep tuner-dev    # anything else already fully merged?
git branch -d <branch-name> <any-other-stale-merged-branches>
```

Tuner-dev itself will sometimes flag already-merged stale branches in a
ticket comment (it checks `git log <branch>..master` in its own worktree
to decide whether something's unmerged) but won't delete them — pruning
the main repo's branch list is explicitly a human call, not something
tuner-dev's manifest lets it do.

## Gotchas

- **A branch fetched into the main repo doesn't exist in the tuner-dev
  worktree's own remote view or on GitHub** until you push — don't expect
  `git branch -a` on GitHub or in the worktree to show it after merging;
  only the main repo and (after step 5) `origin` will.
- **`dev.sh`'s default port collides with production.** Always
  `SIEM_PORT=<something-else>` for any local pipeline testing on this
  host — see step 3.
- **`tests/detections/run-all.sh` can't validate a suppression rule by
  itself** — see step 3's direct-verification steps.
- **Config vs. binary vs. repo path** — always check `systemctl cat
  <unit>` before assuming a merge is live. This "merged ≠ deployed" gap
  is easy to hit repeatedly (a binary fix, a config file that's actually
  read from `/etc/headless-siem/rules/` rather than the repo path, etc.)
  — it's what motivated building `check-deploy-drift` in the first
  place. `scripts/
  redeploy-binary` + `scripts/check-deploy-drift` catch the *binary*
  half of this automatically now; the config-file half still needs the
  manual `systemctl cat`/`diff` check above, there's no tooling for that
  side yet.
- **`check-deploy-drift` only knows about binaries deployed through
  `install.sh` or `redeploy-binary`.** Anything installed by hand before
  this tooling existed shows as `NO RECORD`, not a false "up to date" —
  it's telling you it has no evidence either way, not that something's
  wrong. First `redeploy-binary` run for a given crate on this host
  establishes the baseline.
