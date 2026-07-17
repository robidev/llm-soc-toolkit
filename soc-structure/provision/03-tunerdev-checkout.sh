#!/usr/bin/env bash
#
# 03-tunerdev-checkout.sh
#
# Gives soc-tunerdev its own isolated headless-siem checkout with master
# protected at the OS level (runner-and-permissions.md §5.3). Idempotent;
# requires root. Run: sudo bash 03-tunerdev-checkout.sh
#
# DEVIATION from §5.3's literal "git worktree" -> a dedicated
# `--no-hardlinks` CLONE: a worktree shares
# refs/heads/ and the object store *writably* with the main dev repo, so
# the least-trusted role (tuner-dev executes its own unreviewed code via
# cargo) could write refs/objects into the main repo. A clone gives the
# same isolated-checkout + own-target/ benefits with full ref+object
# isolation. Master protection then applies to the clone's own refs.
#
# Master protection mechanism: master stays a root-owned LOOSE ref inside
# a root-owned STICKY refs/heads/ dir that is group-writable. soc-tunerdev
# (group socroles) can create tuner-dev/* branch refs but, being neither
# the owner of refs/heads/master nor of the refs/heads/ dir, the sticky
# bit forbids it deleting/renaming/replacing master by any git operation.
#
set -euo pipefail

SOC_ROOT=/home/user/projects/llm-soc-toolkit      # [SOC-ROOT-PATH]
SRC_REPO=/home/user/projects/headless-siem       # [SOC-ROOT-PATH] the dev checkout (NOT the live binaries in /usr/local/bin)
CHECKOUT=/var/lib/soc/tunerdev/headless-siem     # soc-tunerdev's own clone; <tuner-dev worktree>
TUNER=soc-tunerdev

log() { printf '  %s\n' "$*"; }
asroot_git() { git -C "$CHECKOUT" "$@"; }
astuner() { sudo -u "$TUNER" -H "$@"; }

[[ $EUID -eq 0 ]] || { echo "must run as root (sudo bash $0)"; exit 1; }
getent passwd "$TUNER" >/dev/null || { echo "$TUNER missing — run 01 first"; exit 1; }
[[ -d $SRC_REPO/.git ]] || { echo "source repo not found: $SRC_REPO"; exit 1; }

echo "== clone (isolated, --no-hardlinks) =="
# soc-tunerdev reads the user-owned source repo during clone/fetch; git's
# dubious-ownership guard needs an explicit exception for that source path
# (read-only; the clone itself is tuner-owned so no exception needed there).
astuner git config --global --add safe.directory "$SRC_REPO" 2>/dev/null || true
astuner git config --global --add safe.directory "$SRC_REPO/.git" 2>/dev/null || true
if [[ -d $CHECKOUT/.git ]]; then
  log "checkout already exists: $CHECKOUT"
else
  [[ -e $CHECKOUT ]] && rm -rf "$CHECKOUT"   # clean a partial/failed prior clone
  astuner git clone --no-hardlinks "$SRC_REPO" "$CHECKOUT"
  astuner git -C "$CHECKOUT" config user.name  "soc-tunerdev"
  astuner git -C "$CHECKOUT" config user.email "soc-tunerdev@localhost"
  log "cloned into $CHECKOUT (owned $TUNER)"
fi

echo "== ensure on master, master is a loose ref =="
astuner git -C "$CHECKOUT" checkout -q master 2>/dev/null || true
# materialize a loose refs/heads/master if it's only packed (source had it
# loose, but be robust); running as tuner while the dir is still tuner-owned
sha="$(astuner git -C "$CHECKOUT" rev-parse master)"
if [[ ! -f "$CHECKOUT/.git/refs/heads/master" ]]; then
  astuner git -C "$CHECKOUT" update-ref refs/heads/master "$sha"
fi
# drop any packed master entry so only the (soon root-owned) loose ref governs
if [[ -f "$CHECKOUT/.git/packed-refs" ]] && grep -q ' refs/heads/master$' "$CHECKOUT/.git/packed-refs"; then
  grep -v ' refs/heads/master$' "$CHECKOUT/.git/packed-refs" > "$CHECKOUT/.git/packed-refs.tmp"
  mv "$CHECKOUT/.git/packed-refs.tmp" "$CHECKOUT/.git/packed-refs"
  chown "$TUNER:socroles" "$CHECKOUT/.git/packed-refs"
  log "removed master from packed-refs (loose ref governs)"
fi
log "master = $sha (loose)"

echo "== protect master at the OS level =="
chown root:socroles "$CHECKOUT/.git/refs/heads"
chmod 1770 "$CHECKOUT/.git/refs/heads"          # sticky + group-writable: create branches, can't touch master
chown root:root "$CHECKOUT/.git/refs/heads/master"
chmod 644 "$CHECKOUT/.git/refs/heads/master"
log "refs/heads = root:socroles 1770 (sticky); refs/heads/master = root:root 644"

# root is the only account that can fast-forward master (that's the whole
# point of the protection above), so root needs its own dubious-ownership
# exception for this soc-tunerdev-owned checkout — same reason astuner
# needed one for $SRC_REPO above. Without this, `soc-run-role`'s per-run
# master sync (see there) fails closed with "detected dubious ownership"
# and tuner-dev silently keeps reasoning off a stale master (found live
# 2026-07-11).
git config --global --add safe.directory "$CHECKOUT" 2>/dev/null || true

echo "== verification =="
stat -c '  refs/heads      %U:%G %a' "$CHECKOUT/.git/refs/heads"
stat -c '  refs/heads/master %U:%G %a' "$CHECKOUT/.git/refs/heads/master"
echo "  HEAD: $(astuner git -C "$CHECKOUT" rev-parse --abbrev-ref HEAD)"
echo "  remotes: $(astuner git -C "$CHECKOUT" remote -v | tr '\n' ' ')"
echo
echo "DONE. tuner-dev checkout ready at $CHECKOUT. Next: set up per-role permission manifests (soc-structure/manifests/)."
