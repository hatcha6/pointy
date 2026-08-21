#!/usr/bin/env bash
#
# Disables the Pointy uptime watchdog on Linux: stops the systemd timer and
# disables it so it never runs at boot or on its 5-minute schedule again.
#
# NOTE — the interval outages were NOT caused by the watchdog (see
# fix-backend-outages.sh: the ASGI workers were self-terminating on a request
# limit; the watchdog only revived the stack afterwards). With the watchdog
# disabled, nothing restarts the stack after a reboot, a power cut, or a
# Docker crash: someone must run `docker compose up -d` by hand. Re-enable at
# any time with:  sudo bash register-autostart.sh
#
# Usage (as root, from anywhere):
#     sudo bash disable-watchdog.sh
# Also disable the 30-minute remote update agent:
#     sudo bash disable-watchdog.sh --include-update-agent
# Remove the systemd units entirely instead of disabling them:
#     sudo bash disable-watchdog.sh --remove
set -euo pipefail

err() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

INCLUDE_UPDATE_AGENT=0
REMOVE=0
for arg in "$@"; do
  case "$arg" in
    --include-update-agent) INCLUDE_UPDATE_AGENT=1 ;;
    --remove) REMOVE=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) err "Unknown argument: $arg" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || err "run as root (sudo bash disable-watchdog.sh)."
command -v systemctl >/dev/null 2>&1 || err "systemd (systemctl) not found — on a cron-based host remove the watchdog crontab entries instead."

UNITS=("pointy-watchdog.timer" "pointy-watchdog.service")
if [ "$INCLUDE_UPDATE_AGENT" -eq 1 ]; then
  UNITS+=("pointy-update-agent.timer" "pointy-update-agent.service")
fi

changed=0
for unit in "${UNITS[@]}"; do
  path="/etc/systemd/system/${unit}"
  if [ ! -f "$path" ]; then
    echo "Unit ${unit} is not installed — nothing to do."
    continue
  fi
  systemctl stop "$unit" 2>/dev/null || true
  systemctl disable "$unit" 2>/dev/null || true
  if [ "$REMOVE" -eq 1 ]; then
    rm -f "$path"
    echo "Unit ${unit} stopped and REMOVED."
  else
    echo "Unit ${unit} stopped and DISABLED (boot + interval triggers inert)."
  fi
  changed=1
done
[ "$REMOVE" -eq 1 ] && systemctl daemon-reload

if [ "$changed" -eq 1 ]; then
  echo ""
  echo "The watchdog no longer runs at boot or on its 5-minute schedule."
  echo "Remember: after a reboot or power cut the stack must now be started"
  echo "manually:  docker compose --env-file .env -f docker-compose.yml up -d"
  echo "Re-enable auto-recovery later with:  sudo bash register-autostart.sh"
fi
