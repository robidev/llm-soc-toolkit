#!/usr/bin/env bash
#
# 11-systemd-timers.sh
#
# Installs all seven systemd timer/service pairs and enables them, so a
# fresh/reprovisioned host reproduces the current live cron topology
# (all 4 roles on cron, offsets resolved) -- ExecStart points at
# $SOC_ROOT/scripts/... directly (no /usr/local/bin copy, unlike the
# trusted helpers in 02/05/07/08/09/10), so there's no stale-copy drift
# to worry about:
#
#   - soc-baseline.timer   -- daily baseline digest capture,
#     scripts/capture-baseline, noon (deliberately off the midnight
#     bucket-rollover window, see the .timer file's own comment)
#   - soc-session-cleanup.timer      -- weekly transcript cleanup,
#     scripts/soc-session-cleanup
#   - soc-analyst.timer              -- hourly (:00), scripts/soc-run-role
#     analyst. Deliberately NOT paired with agent-watchdog yet -- a
#     reduced-cadence starting point to observe token usage before the
#     full target cadence (every 10 min + watchdog together). Revisit
#     before treating this as a real go-live cadence.
#   - soc-soclead-nightly.timer      -- daily 02:00, scripts/soc-run-role
#     soclead (medium effort, 24h window).
#   - soc-soclead-weekly.timer       -- Sunday 03:00, scripts/soc-run-role
#     --weekly soclead (high effort, 7-day window + trend analysis). The
#     --weekly flag and the nightly/weekly mode-envelope plumbing it
#     depends on (prompts/soclead-{nightly,weekly}-mode.md) support both
#     timers.
#   - soc-specialist.timer           -- hourly (:20), scripts/soc-run-role
#     specialist. Offset 20min after analyst's :00 so the two roles' runs
#     don't overlap, rather than accepting the overlap or staggering
#     further. soc-run-role also gates specialist on an
#     empty ticket queue, so an hourly tick
#     with nothing assigned skips instead of spending a real pass.
#   - soc-tuner-dev.timer            -- every 5h (:40), scripts/soc-run-role
#     tuner-dev. Offset 20min after specialist (40min after analyst),
#     same every-5h cadence (hours 0,5,10,...) just off the whole-hour
#     mark, for the same overlap-avoidance reason. Same
#     empty-queue gate applies.
#
# NOT paired with any of these: agent-watchdog (dead-cron paging). Left
# off deliberately for this homelab-scale, low-stakes setup -- a silent
# cron death is caught only by soclead's next nightly "role that didn't
# log" scan (up to ~24h blind), not paged in real time. Revisit if that
# tradeoff stops being acceptable.
#
# All nine units are idempotent to install; requires root.
#   sudo bash 11-systemd-timers.sh
#
set -euo pipefail

SOC_ROOT=/home/user/projects/llm-soc-toolkit   # [SOC-ROOT-PATH]
UNIT_DIR="$SOC_ROOT/config/systemd"
DEST=/etc/systemd/system

log() { printf '  %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "must run as root (sudo bash $0)"; exit 1; }

echo "== install systemd units =="
for unit in soc-baseline.service soc-baseline.timer \
            soc-session-cleanup.service soc-session-cleanup.timer \
            soc-analyst.service soc-analyst.timer \
            soc-soclead-nightly.service soc-soclead-nightly.timer \
            soc-soclead-weekly.service soc-soclead-weekly.timer \
            soc-specialist.service soc-specialist.timer \
            soc-tuner-dev.service soc-tuner-dev.timer; do
    SRC="$UNIT_DIR/$unit"
    [[ -f $SRC ]] || { echo "source not found: $SRC"; exit 1; }
    install -o root -g root -m 644 "$SRC" "$DEST/$unit"
    log "installed $DEST/$unit"
done

systemctl daemon-reload
log "systemd daemon-reload complete"

echo "== enable + start timers =="
systemctl enable --now soc-baseline.timer
log "soc-baseline.timer enabled + active"
systemctl enable --now soc-session-cleanup.timer
log "soc-session-cleanup.timer enabled + active"
systemctl enable --now soc-analyst.timer
log "soc-analyst.timer enabled + active"
systemctl enable --now soc-soclead-nightly.timer
log "soc-soclead-nightly.timer enabled + active"
systemctl enable --now soc-soclead-weekly.timer
log "soc-soclead-weekly.timer enabled + active"
systemctl enable --now soc-specialist.timer
log "soc-specialist.timer enabled + active"
systemctl enable --now soc-tuner-dev.timer
log "soc-tuner-dev.timer enabled + active"

echo "DONE."
