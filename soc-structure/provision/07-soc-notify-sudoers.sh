#!/usr/bin/env bash
#
# 07-soc-notify-sudoers.sh
#
# Grants every role NOPASSWD sudo to run scripts/soc-notify as soc-infra
# (not root -- soc-notify needs no more privilege than that, and running
# it as soc-infra keeps .notify-count/ ownership consistent with every
# other soc-infra-authored artifact). Every role manifest has allow-listed
# this exact `sudo -u soc-infra .../soc-notify <priority> *` invocation
# since §6 was first written, but the sudoers grant to make it possible
# was never actually provisioned until this was found (alongside the
# separate NoNewPrivileges/sudo conflict, same investigation).
#
# Which PRIORITY a role may actually invoke stays enforced at the
# Claude-Code manifest layer (per-role allow/deny Bash patterns), not
# here -- this rule only grants running the script at all, same
# "arg validation lives in the tool/manifest, not sudoers" precedent
# 02-ticket-assign.sh's rule already follows.
#
# Idempotent; requires root.  sudo bash 07-soc-notify-sudoers.sh
#
set -euo pipefail

SOC_NOTIFY=/home/user/projects/llm-soc-toolkit/scripts/soc-notify   # [SOC-ROOT-PATH]
SUDOERS=/etc/sudoers.d/soc-notify

log() { printf '  %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "must run as root (sudo bash $0)"; exit 1; }
[[ -f $SOC_NOTIFY ]] || { echo "source not found: $SOC_NOTIFY"; exit 1; }

echo "== sudoers: every role may run soc-notify as soc-infra =="
tmp="$(mktemp)"
cat > "$tmp" <<EOF
# soc SOC soc-notify — role accounts run the notify wrapper as soc-infra
# (not root). Which PRIORITY a given role may actually invoke is enforced
# by the Claude-Code-level manifest, not this rule. Reuses the SOC_ROLES
# User_Alias defined in soc-ticket-assign (sudoers aliases are global
# across /etc/sudoers.d/ and error on redefinition -- do not redeclare
# SOC_ROLES here).
Cmnd_Alias  SOC_NOTIFY  = $SOC_NOTIFY
SOC_ROLES ALL=(soc-infra) NOPASSWD: SOC_NOTIFY
EOF
# This rule references the SOC_ROLES alias from soc-ticket-assign's own
# file, so it only validates standalone if that file is already installed
# (matches this project's real deployment order -- 02 runs before 07).
if [[ -f /etc/sudoers.d/soc-ticket-assign ]]; then
  visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; echo "sudoers validation FAILED"; exit 1; }
else
  log "WARNING: /etc/sudoers.d/soc-ticket-assign not installed yet -- skipping pre-install"
  log "  visudo -cf check (SOC_ROLES alias not yet defined); run 02-ticket-assign.sh first"
fi
install -o root -g root -m 440 "$tmp" "$SUDOERS"; rm -f "$tmp"
visudo -c >/dev/null
log "installed + validated $SUDOERS (440)"

echo "DONE."
