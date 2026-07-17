#!/usr/bin/env bash
#
# 12-rdap-lookup.sh
#
# Installs the RDAP IP-registration lookup (scripts/rdap-lookup). Same
# trust shape as 08-ticket-route.sh: read-only, unprivileged, no sudoers
# rule, runs as whichever role calls it straight off the sandbox PATH
# shim. It takes one argument (an IP), validates it strictly, and makes
# exactly one outbound GET to a URL it builds itself
# (https://rdap.org/ip/<validated-ip>) -- no argument surface for a
# prompt-injected log line to redirect the request anywhere else.
#
# This grants sandboxed roles their first real outbound-internet call
# (see runbooks/haproxy.md's "Known-benign: registered
# office/admin access" pattern -- verifying an unfamiliar IP's registrant
# before trusting an "it's probably the office" read). The main role
# sandboxes are already not network-namespace-isolated (PrivateNetwork=yes
# is infeasible since `claude` itself needs the Anthropic API) -- this
# script doesn't change that boundary, it's the first thing allow-listed
# to actually use it.
#
# Idempotent; requires root.  sudo bash 12-rdap-lookup.sh
#
set -euo pipefail

SOC_ROOT=/home/user/projects/llm-soc-toolkit   # [SOC-ROOT-PATH]
SRC="$SOC_ROOT/scripts/rdap-lookup"
BIN=/usr/local/bin/rdap-lookup

log() { printf '  %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "must run as root (sudo bash $0)"; exit 1; }
[[ -f $SRC ]]     || { echo "source not found: $SRC"; exit 1; }

echo "== install rdap-lookup =="
install -o root -g root -m 755 "$SRC" "$BIN"
log "installed $BIN (root:root 755)"

echo "DONE."
