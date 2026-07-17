#!/usr/bin/env bash
#
# 06-restart-pipeline.sh — implements runner-and-permissions.md §10
# (soc-restart-pipeline availability mitigation).
#
# Installs soc-restart-pipeline root-owned to /usr/local/bin (integrity,
# same pattern as ticket-assign) and grants the analyst NOPASSWD sudo to
# it. Idempotent; requires root.  sudo bash 06-restart-pipeline.sh
#
set -euo pipefail

SRC=/home/user/projects/headless-siem/scripts/soc-restart-pipeline   # dev source (not [SOC-ROOT]; headless-siem tree)
BIN=/usr/local/bin/soc-restart-pipeline
SUDOERS=/etc/sudoers.d/soc-restart-pipeline
STATE_DIR=/var/lib/soc/restart-state

log() { printf '  %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "must run as root (sudo bash $0)"; exit 1; }
[[ -f $SRC ]] || { echo "source not found: $SRC"; exit 1; }

echo "== install binary (root-owned, integrity) =="
install -o root -g root -m 755 "$SRC" "$BIN"
log "installed $BIN (root:root 755)"

echo "== rate-limit state dir =="
install -d -o root -g root -m 755 "$STATE_DIR"
log "$STATE_DIR ready"

echo "== sudoers: analyst only (per decisions 4.10 the analyst owns pipeline recovery) =="
tmp="$(mktemp)"
cat > "$tmp" <<'EOF'
# soc-restart-pipeline — the analyst may run the fixed no-arg recovery
# helper as root. It takes NO arguments and its behaviour is fully fixed,
# so there is no argument surface to constrain; this rule only names who
# may run which exact binary.
soc-analyst ALL=(root) NOPASSWD: /usr/local/bin/soc-restart-pipeline
EOF
visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; echo "sudoers validation FAILED"; exit 1; }
install -o root -g root -m 440 "$tmp" "$SUDOERS"; rm -f "$tmp"
visudo -cf "$SUDOERS" >/dev/null
log "installed + validated $SUDOERS (440)"

echo "DONE. Manifest/prompt reference /usr/local/bin/soc-restart-pipeline."
