#!/usr/bin/env bash
#
# 09-ticket-reassign.sh
#
# Installs the ticket-reassign helper (scripts/ticket-reassign). Same as
# ticket-route: no sudoers rule needed at all -- unprivileged, reads
# CLAUDE_ROLE (set by soc-run-role for every sandboxed invocation) to
# determine the caller's own folder, and only ever touches paths already
# in that role's own ReadWritePaths (its own folder + unassigned/).
#
# Idempotent; requires root.  sudo bash 09-ticket-reassign.sh
#
set -euo pipefail

SOC_ROOT=/home/user/projects/llm-soc-toolkit   # [SOC-ROOT-PATH]
SRC="$SOC_ROOT/scripts/ticket-reassign"
BIN=/usr/local/bin/ticket-reassign

log() { printf '  %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "must run as root (sudo bash $0)"; exit 1; }
[[ -f $SRC ]]     || { echo "source not found: $SRC"; exit 1; }

echo "== install ticket-reassign =="
install -o root -g root -m 755 "$SRC" "$BIN"
log "installed $BIN (root:root 755)"

echo "DONE."
