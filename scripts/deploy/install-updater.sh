#!/bin/bash
# install-updater.sh — Install systemd timer for periodic repo updates.
#
# Creates a system-level timer that runs update.sh every 6 hours.
# Idempotent — safe to re-run.

set -euo pipefail

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
skip()  { echo "  SKIP: $* (already done)"; }

# Wrap sudo
if [[ $EUID -eq 0 ]]; then
    sudo() { "$@"; }
fi

# Detect the non-root user (the one who owns ~/dev-env)
if [[ $EUID -eq 0 ]]; then
    RUN_USER="${SUDO_USER:-ubuntu}"
else
    RUN_USER="$USER"
fi

RUN_HOME=$(eval echo "~$RUN_USER")
SERVICE_NAME="claude-update"

info "Auto-updater (systemd timer)"

# Create service unit
cat <<EOF | sudo tee /etc/systemd/system/${SERVICE_NAME}.service >/dev/null
[Unit]
Description=Pull latest always-on-claude updates
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$RUN_USER
Environment=HOME=$RUN_HOME
ExecStart=/bin/bash $RUN_HOME/dev-env/scripts/runtime/update.sh
EOF

# Create timer unit
cat <<EOF | sudo tee /etc/systemd/system/${SERVICE_NAME}.timer >/dev/null
[Unit]
Description=Check for always-on-claude updates every 6 hours

[Timer]
OnCalendar=*-*-* 00/6:00:00
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ${SERVICE_NAME}.timer

ok "Systemd timer installed and enabled (every 6 hours)"
