#!/usr/bin/env bash
#
# Registers the Pointy uptime watchdog with systemd so the till comes back
# online by itself after a reboot, crash, or power cut.
#
# Run this ONCE from inside the bundle, as root:
#
#     sudo bash register-autostart.sh
#
# It installs a systemd timer that runs watchdog.sh ~30s after boot and every
# 5 minutes thereafter. watchdog.sh runs `docker compose up -d` (recreating any
# destroyed/stopped container) and restarts wedged "unhealthy" containers.
# Together with `restart: always` in the compose file this gives hands-off,
# outage-free operation.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run as root (sudo bash register-autostart.sh)." >&2
  exit 1
fi
command -v systemctl >/dev/null 2>&1 || {
  echo "ERROR: systemd (systemctl) not found. On a non-systemd host, add a cron" >&2
  echo "       @reboot entry plus a */5 entry that run: bash ${HERE}/watchdog.sh" >&2
  exit 1
}

SERVICE=/etc/systemd/system/pointy-watchdog.service
TIMER=/etc/systemd/system/pointy-watchdog.timer

echo "==> Writing ${SERVICE}"
cat > "${SERVICE}" <<EOF
[Unit]
Description=Pointy uptime watchdog (reconcile + heal the on-prem stack)
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=oneshot
WorkingDirectory=${HERE}
ExecStart=/usr/bin/env bash ${HERE}/watchdog.sh
EOF

echo "==> Writing ${TIMER}"
cat > "${TIMER}" <<EOF
[Unit]
Description=Run the Pointy uptime watchdog at boot and every 5 minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
AccuracySec=15s
Persistent=true
Unit=pointy-watchdog.service

[Install]
WantedBy=timers.target
EOF

UPDATE_SERVICE=/etc/systemd/system/pointy-update-agent.service
UPDATE_TIMER=/etc/systemd/system/pointy-update-agent.timer

if [ -f "${HERE}/update-agent.sh" ]; then
  echo "==> Writing ${UPDATE_SERVICE}"
  cat > "${UPDATE_SERVICE}" <<EOF
[Unit]
Description=Pointy remote update agent (pull + apply the relay-assigned version)
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=oneshot
WorkingDirectory=${HERE}
ExecStart=/usr/bin/env bash ${HERE}/update-agent.sh
EOF

  echo "==> Writing ${UPDATE_TIMER}"
  cat > "${UPDATE_TIMER}" <<EOF
[Unit]
Description=Run the Pointy remote update agent shortly after boot and periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
AccuracySec=1min
Persistent=true
Unit=pointy-update-agent.service

[Install]
WantedBy=timers.target
EOF
fi

DISCOVERY_SERVICE=/etc/systemd/system/pointy-discovery.service

# LAN discovery responder: Docker's published UDP port never receives the
# clients' broadcast probes, so the responder must live on the host.
if [ -f "${HERE}/discovery-responder.py" ]; then
  if command -v python3 >/dev/null 2>&1; then
    echo "==> Writing ${DISCOVERY_SERVICE}"
    cat > "${DISCOVERY_SERVICE}" <<EOF
[Unit]
Description=Pointy LAN discovery responder (answers POS clients on udp/47777)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${HERE}
ExecStart=/usr/bin/env python3 ${HERE}/discovery-responder.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  else
    echo "WARN: python3 not found — skipping the LAN discovery responder." >&2
    echo "      Install python3 and re-run, or clients must type the server IP." >&2
  fi
fi

echo "==> Enabling timers"
systemctl daemon-reload
systemctl enable --now pointy-watchdog.timer
systemctl start pointy-watchdog.service || true
if [ -f "${UPDATE_TIMER}" ]; then
  systemctl enable --now pointy-update-agent.timer
fi
if [ -f "${DISCOVERY_SERVICE}" ]; then
  systemctl enable --now pointy-discovery.service
fi

# Make Docker itself start on boot (the Linux counterpart of register-autostart.ps1
# setting Docker Desktop to start at login). Best-effort: rootless/custom setups
# may not ship a docker.service unit.
echo "==> Ensuring Docker starts on boot"
if systemctl enable docker >/dev/null 2>&1; then
  echo "    docker.service enabled."
else
  echo "WARN: could not enable docker.service — make sure Docker starts on boot yourself."
fi

echo ""
echo "Done. The watchdog runs ~30s after every boot and every 5 minutes."
echo "The update agent runs ~2min after boot and every 30 minutes."
echo "The LAN discovery responder runs continuously on udp/47777."
echo "Inspect with:"
echo "  systemctl status pointy-watchdog.timer pointy-update-agent.timer pointy-discovery.service"
echo "  journalctl -u pointy-watchdog.service -f"
echo "  journalctl -u pointy-update-agent.service -f"
echo "  journalctl -u pointy-discovery.service -f"
