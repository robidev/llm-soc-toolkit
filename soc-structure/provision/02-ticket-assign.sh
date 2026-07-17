#!/usr/bin/env bash
#
# 02-ticket-assign.sh
#
# Installs the ticket-assign trusted helper and its narrowly scoped
# sudoers rule. Idempotent; requires root. Run:
#   sudo bash 02-ticket-assign.sh
#
# Depends on 01-users-and-perms.sh having run (needs the soc-* users,
# socroles group, and permission-audit/).
#
set -euo pipefail

SOC_ROOT=/home/user/projects/llm-soc-toolkit   # [SOC-ROOT-PATH]
SRC="$SOC_ROOT/scripts/ticket-assign"
BIN=/usr/local/bin/ticket-assign
SUDOERS=/etc/sudoers.d/soc-ticket-assign
AUDIT="$SOC_ROOT/permission-audit/ticket-assign.log"

log() { printf '  %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "must run as root (sudo bash $0)"; exit 1; }
[[ -f $SRC ]]     || { echo "helper source not found: $SRC"; exit 1; }
getent group socroles >/dev/null || { echo "socroles group missing — run 01 first"; exit 1; }

echo "== install helper binary =="
install -o root -g root -m 755 "$SRC" "$BIN"
log "installed $BIN (root:root 755)"

echo "== install sudoers rule =="
# Arg-safety is enforced INSIDE the helper, NOT here: sudo command-line
# arg matching is a known footgun (a rule that looks argument-restricted
# usually isn't). This rule only controls WHO may run the binary as root;
# the binary itself validates containment, filename shape, and collisions.
tmp="$(mktemp)"
cat > "$tmp" <<'EOF'
# soc SOC ticket-assign — role accounts run the trusted helper as root.
# Arg validation lives in /usr/local/bin/ticket-assign, not in this rule.
User_Alias  SOC_ROLES     = soc-analyst, soc-specialist, soc-tunerdev, soc-soclead, soc-infra
Cmnd_Alias  TICKET_ASSIGN = /usr/local/bin/ticket-assign
SOC_ROLES ALL=(root) NOPASSWD: TICKET_ASSIGN
EOF
# validate before installing so a typo can never wedge sudo
visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; echo "sudoers validation FAILED — not installed"; exit 1; }
install -o root -g root -m 440 "$tmp" "$SUDOERS"
rm -f "$tmp"
visudo -cf "$SUDOERS" >/dev/null
log "installed + validated $SUDOERS (440)"

echo "== ensure audit log exists =="
touch "$AUDIT"; chown root:socroles "$AUDIT"; chmod 640 "$AUDIT"
log "$AUDIT ready (root:socroles 640)"

echo "DONE. ticket-assign installed. Next: tuner-dev worktree + read-only master ref (03-tunerdev-checkout.sh)."
