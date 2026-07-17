#!/usr/bin/env bash
#
# 05-siemctl-shim.sh — implements runner-and-permissions.md §10 (siemctl
# PATH shim mitigation)
#
# Installs the root-owned siemctl shim that pins --data-dir, and applies
# the siemctl access grant (analyst may write the ack watermark).
# Idempotent; requires root.  sudo bash 05-siemctl-shim.sh
#
# NOTE for the runner (item E / base wrapper): each role's PATH must put
# SHIM_DIR *before* /usr/local/bin so `siemctl` resolves to the shim, e.g.
#   systemd-run ... --setenv=PATH=/usr/local/lib/soc/bin:/usr/bin:/bin ...
#
set -euo pipefail

SOC_ROOT=/home/user/projects/llm-soc-toolkit      # [SOC-ROOT-PATH]
SHIM_SRC="$SOC_ROOT/scripts/siemctl-shim"
SHIM_DIR=/usr/local/lib/soc/bin
REAL=/usr/local/bin/siemctl
ACK=/var/lib/headless-siem/alerts/ack.jsonl

log() { printf '  %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "must run as root (sudo bash $0)"; exit 1; }
[[ -f $SHIM_SRC ]] || { echo "shim source not found: $SHIM_SRC"; exit 1; }
[[ -x $REAL ]] || { echo "real siemctl not found at $REAL"; exit 1; }

echo "== install siemctl shim =="
install -d -o root -g root -m 755 "$SHIM_DIR"
install -o root -g root -m 755 "$SHIM_SRC" "$SHIM_DIR/siemctl"
log "installed $SHIM_DIR/siemctl (root:root 755) -> pins --data-dir, execs $REAL"

echo "== siemctl access: analyst may write the ack watermark =="
# Data-dir group read is already satisfied by the live tree's 775/664
# ('other' read). Only the single ack.jsonl needs a writer grant: it is
# written ONLY by siemctl (services read it), and only the analyst
# acks. Owner soc-analyst (write), group+other read so
# ruled/correlated (running as 'user') still read it for suppression.
if [[ -f $ACK ]]; then
  chown soc-analyst:socroles "$ACK"; chmod 664 "$ACK"
  log "$ACK -> soc-analyst:socroles 664 (analyst writes, services read)"
else
  log "WARN: $ACK not present; analyst ack write grant skipped (create then re-run)"
fi

echo "DONE. siemctl shim installed. Runner must prepend $SHIM_DIR to each role's PATH."
