#!/usr/bin/env bash
# gx10-thermal-watch.sh — thermal safety watchdog for a GB10 / DGX Spark node.
#
# Reads the hottest ACPI/SoC thermal zone (in millidegrees) every INTERVAL sec.
# If it stays at/above THRESHOLD for CONSECUTIVE consecutive samples, it:
#   1) cleanly powers off a designated peer node (the other cluster rank) via SSH,
#   2) verifies the peer actually went down, then
#   3) cleanly powers off THIS node.
#
# Rationale: the GB10's EC hard power-cuts at ~96C (log-less) when the SoC/acpitz
# package zone crosses it. This watchdog trips a few degrees earlier and issues a
# CLEAN systemctl poweroff so the node (and its cluster peer) shut down safely
# and leave a journal entry. Zero performance impact — it only acts on overheat.
#
# Run on the single hottest node (e.g. the head/rank-0). Set PEER_HOST to the
# other cluster node it should shut down first. No hostnames are hardcoded.
#
# Env overrides (systemd unit sets these):
#   THRESHOLD    mC for trip (default 95000 = 95.0C; EC cuts ~96C)
#   CONSECUTIVE  samples over threshold before firing (default 3)
#   INTERVAL     seconds between samples (default 30 -> 90s sustained window)
#   PEER_HOST    hostname/addr of the peer node to power off first (default none)
#   DRY_RUN      1 = print what it would do, do NOT power off (test only)
set -uo pipefail

THRESHOLD=${THRESHOLD:-95000}
CONSECUTIVE=${CONSECUTIVE:-3}
INTERVAL=${INTERVAL:-30}
PEER_HOST=${PEER_HOST:-}
DRY_RUN=${DRY_RUN:-0}

hot() {
  # hottest readable /sys thermal zone temp in mC, or empty
  local m=-1 v
  for z in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$z" ] || continue
    v=$(cat "$z" 2>/dev/null) || continue
    case "$v" in ''|*[!0-9]*) continue;; esac
    [ "$v" -gt "$m" ] 2>/dev/null && m=$v
  done
  [ "$m" -gt 0 ] && echo "$m" || echo ""
}

n=0
while true; do
  t=$(hot)
  if [ -z "$t" ]; then
    echo "$(date +%H:%M:%S) watch: no thermal zone readable"
    sleep "$INTERVAL"; continue
  fi
  if [ "$t" -ge "$THRESHOLD" ]; then
    n=$((n+1))
    echo "$(date +%H:%M:%S) watch: ${t}mC (=$((t/1000)).$((t%1000/100))C) >= ${THRESHOLD}mC streak=$n/$CONSECUTIVE"
    if [ "$n" -ge "$CONSECUTIVE" ]; then
      if [ "$DRY_RUN" = "1" ]; then
        echo "$(date +%H:%M:%S) [DRY-RUN] would power off peer '${PEER_HOST:-none}' then THIS node. Not shutting down."
      else
        echo "$(date +%H:%M:%S) THERMAL TRIP ${t}mC. Ordered shutdown: peer first, then this node."
        logger -t gx10-thermal-watch "Thermal trip ${t}mC. Ordered shutdown peer->this."
        # 1) power off the peer, then confirm it went down (bounded wait)
        if [ -n "$PEER_HOST" ]; then
          ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
              "$PEER_HOST" "sudo -n systemctl poweroff" 2>/dev/null || true
          for i in $(seq 1 12); do
            if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$PEER_HOST" true 2>/dev/null; then
              echo "$(date +%H:%M:%S) peer ${PEER_HOST} confirmed down (attempt $i)."; break
            fi
            sleep 5
          done
        fi
        # 2) cleanly power off THIS node
        systemctl poweroff
        exit 0
      fi
      n=0
    fi
  else
    n=0
  fi
  sleep "$INTERVAL"
done
