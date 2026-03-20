#!/bin/bash
# install-disk-monitor.sh — Install systemd timer for disk usage monitoring.
#
# Creates a system-level timer that checks disk usage every hour.
# Idempotent — safe to re-run.

set -euo pipefail

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
skip()  { echo "  SKIP: $* (already done)"; }

# Wrap sudo
if [[ $EUID -eq 0 ]]; then
    sudo() { "$@"; }
fi

# Detect the non-root user
if [[ $EUID -eq 0 ]]; then
    RUN_USER="${SUDO_USER:-dev}"
else
    RUN_USER="$USER"
fi

RUN_HOME=$(eval echo "~$RUN_USER")
SERVICE_NAME="disk-monitor"

info "Disk monitor (systemd timer)"

# Create service unit
cat <<EOF | sudo tee /etc/systemd/system/${SERVICE_NAME}.service >/dev/null
[Unit]
Description=Monitor disk usage and alert before capacity
After=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/bin/bash $RUN_HOME/dev-env/scripts/runtime/disk-monitor.sh
EOF

# Create timer unit
cat <<EOF | sudo tee /etc/systemd/system/${SERVICE_NAME}.timer >/dev/null
[Unit]
Description=Check disk usage every hour

[Timer]
OnCalendar=*-*-* *:00:00
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ${SERVICE_NAME}.timer

ok "Disk monitor timer installed and enabled (every hour)"
