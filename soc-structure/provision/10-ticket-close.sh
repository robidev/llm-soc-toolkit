#!/usr/bin/env bash
#
# 10-ticket-close.sh
#
# Ensures a ticket's `status: closed` and its CLOSED_ filename rename
# always happen atomically, in the same edit, so the two can never drift.
#
# Installs the ticket-close helper (scripts/ticket-close). Same as
# ticket-route/ticket-reassign: no sudoers rule needed at all --
# unprivileged, reads CLAUDE_ROLE (set by soc-run-role for every
# sandboxed invocation) to determine the caller's own folder, and only
# ever renames/edits a ticket already owned by that role in its own
# ReadWritePaths.
#
# Was previously installed by hand (`install -m 755`, undocumented as a
# repeatable step) when scripts/ticket-close was built; this fills the
# gap so a reprovisioned host doesn't lose it.
#
# Idempotent; requires root.  sudo bash 10-ticket-close.sh
#
set -euo pipefail

SOC_ROOT=/home/user/projects/llm-soc-toolkit   # [SOC-ROOT-PATH]
SRC="$SOC_ROOT/scripts/ticket-close"
BIN=/usr/local/bin/ticket-close

log() { printf '  %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "must run as root (sudo bash $0)"; exit 1; }
[[ -f $SRC ]]     || { echo "source not found: $SRC"; exit 1; }

echo "== install ticket-close =="
install -o root -g root -m 755 "$SRC" "$BIN"
log "installed $BIN (root:root 755)"

echo "DONE."
