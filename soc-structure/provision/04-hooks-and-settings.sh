#!/usr/bin/env bash
#
# 04-hooks-and-settings.sh
#
# Installs the PreToolUse hook + per-role settings + append-only audit
# logs into root-owned /etc/soc/ (the integrity point, §5.1/§7). Wires
# the hook in audit mode. Idempotent; requires root.
#   sudo bash 04-hooks-and-settings.sh
#
# Audit mode here means the hook logs out-of-manifest calls but never blocks;
# the only native blocks are a narrow catastrophic deny list. Flipping
# /etc/soc/hook-mode to "enforce" (and re-running scripts/soc-build-settings)
# promotes each manifest into the settings' native allow/deny + defaultMode
# dontAsk.
#
set -euo pipefail

SOC_ROOT=/home/user/projects/llm-soc-toolkit      # [SOC-ROOT-PATH]
ETC=/etc/soc
HOOK_SRC="$SOC_ROOT/scripts/hook-check"
MANIF_SRC="$SOC_ROOT/soc-structure/manifests"
AUDIT_DIR="$SOC_ROOT/permission-audit"

log() { printf '  %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "must run as root (sudo bash $0)"; exit 1; }
[[ -f $HOOK_SRC ]] || { echo "hook not found: $HOOK_SRC"; exit 1; }
getent group socroles >/dev/null || { echo "run 01 first"; exit 1; }

echo "== /etc/soc (root-owned integrity home) =="
install -d -o root -g root -m 755 "$ETC"

echo "== hook + manifests + mode =="
install -o root -g root -m 755 "$HOOK_SRC" "$ETC/hook-check"
for r in analyst specialist tuner-dev soclead; do
  install -o root -g root -m 644 "$MANIF_SRC/manifest-enforced-$r.json" "$ETC/manifest-enforced-$r.json"
done
# default to audit; never clobber an operator's later flip to enforce
[[ -f $ETC/hook-mode ]] || printf 'audit\n' > "$ETC/hook-mode"
chown root:root "$ETC/hook-mode"; chmod 644 "$ETC/hook-mode"
log "hook-check, 4 manifests, hook-mode=$(cat "$ETC/hook-mode") installed"

echo "== per-role settings.json (audit mode: hook + narrow catastrophic deny) =="
for r in analyst specialist tuner-dev soclead; do
  cat > "$ETC/$r-settings.json" <<'JSON'
{
  "_meta": "Audit mode. hook-check logs out-of-manifest calls, never blocks. Native deny below is the only block in this mode. Enforce mode adds the manifest allow/deny + defaultMode dontAsk.",
  "permissions": {
    "deny": [
      "Read(documentation/canary-hosts.md)",
      "Bash(rm -rf /*)",
      "Bash(rm -rf ~*)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      { "hooks": [ { "type": "command", "command": "/etc/soc/hook-check", "timeout": 30 } ] }
    ]
  }
}
JSON
  chown root:root "$ETC/$r-settings.json"; chmod 644 "$ETC/$r-settings.json"
done
log "4 settings files written (root:root 644)"

echo "== per-role append-only audit logs =="
install -d -o root -g socroles -m 750 "$AUDIT_DIR"
for r in analyst specialist tuner-dev soclead; do
  u="soc-${r/tuner-dev/tunerdev}"
  f="$AUDIT_DIR/$r.log"
  [[ -f $f ]] || { touch "$f"; }
  # remove any prior append-only flag so chown/chmod can be reapplied idempotently
  chattr -a "$f" 2>/dev/null || true
  chown "$u:socroles" "$f"; chmod 600 "$f"
  if chattr +a "$f" 2>/dev/null; then log "$r.log -> $u:socroles 600 +a (append-only)"
  else log "$r.log -> $u:socroles 600 (chattr +a unsupported on this fs — appendable but truncatable by owner)"; fi
done

echo "DONE. Hook wired in AUDIT mode. Next: escalation wrapper, then the siemctl shim, then a manual audit-mode dry-run per role."
