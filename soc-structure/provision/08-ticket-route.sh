#!/usr/bin/env bash
#
# 08-ticket-route.sh
#
# Installs the ticket-route validator (scripts/ticket-route). Unlike
# ticket-assign/soc-notify this needs NO sudoers rule at all -- it's
# read-only, unprivileged, and runs as whichever role calls it, straight
# off the sandbox PATH shim. It only re-validates the assigned_to:
# frontmatter field a role already wrote; the actual privileged move is
# scripts/ticket-route-sweep, called from soc-run-role itself and never
# deployed outside the repo (soc-run-role always runs from $SOC_ROOT).
#
# Idempotent; requires root.  sudo bash 08-ticket-route.sh
#
set -euo pipefail

SOC_ROOT=/home/user/projects/llm-soc-toolkit   # [SOC-ROOT-PATH]
SRC="$SOC_ROOT/scripts/ticket-route"
BIN=/usr/local/bin/ticket-route

log() { printf '  %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "must run as root (sudo bash $0)"; exit 1; }
[[ -f $SRC ]]     || { echo "source not found: $SRC"; exit 1; }

echo "== install ticket-route =="
install -o root -g root -m 755 "$SRC" "$BIN"
log "installed $BIN (root:root 755)"

echo "DONE."
