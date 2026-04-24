#!/bin/bash
# install-schedule-bridge.sh — Install host bridge for container scheduling.

set -euo pipefail

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
skip()  { echo "  SKIP: $* (already done)"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

if [[ $EUID -eq 0 ]]; then
    sudo() { "$@"; }
fi

TARGET_USER="${AOC_USER:-dev}"
id "$TARGET_USER" >/dev/null 2>&1 || die "User not found: $TARGET_USER"

if command -v getent >/dev/null 2>&1; then
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
else
    TARGET_HOME="$(eval "printf '%s' ~$TARGET_USER")"
fi
TARGET_GROUP="$(id -gn "$TARGET_USER")"
DEV_ENV="${DEV_ENV:-$TARGET_HOME/dev-env}"
SCHEDULE_DIR="${AOC_SCHEDULE_DIR:-$TARGET_HOME/.always-on-claude/schedule}"
SERVICE_NAME="always-on-claude-schedule-bridge"

command -v systemctl >/dev/null 2>&1 || die "systemctl is required"
[[ -x "$DEV_ENV/scripts/runtime/process-schedule-requests.sh" ]] || \
    die "Missing executable processor: $DEV_ENV/scripts/runtime/process-schedule-requests.sh"

info "Schedule bridge"

for dir in inbox processing jobs logs status; do
    mkdir -p "$SCHEDULE_DIR/$dir"
done
chown -R "$TARGET_USER:$TARGET_GROUP" "$SCHEDULE_DIR"
chmod 700 "$SCHEDULE_DIR" "$SCHEDULE_DIR/inbox" "$SCHEDULE_DIR/processing" "$SCHEDULE_DIR/jobs"
chmod 755 "$SCHEDULE_DIR/logs" "$SCHEDULE_DIR/status"
ok "Schedule directories ready"

missing_packages=()
command -v at >/dev/null 2>&1 || missing_packages+=("at")
command -v crontab >/dev/null 2>&1 || missing_packages+=("cron")

if [[ ${#missing_packages[@]} -gt 0 ]]; then
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${missing_packages[@]}"
        ok "Installed ${missing_packages[*]}"
    else
        die "${missing_packages[*]} required but apt-get is unavailable"
    fi
else
    skip "at and cron"
fi

sudo systemctl enable --now atd.service >/dev/null 2>&1
ok "atd enabled"

if systemctl list-unit-files cron.service >/dev/null 2>&1; then
    sudo systemctl enable --now cron.service >/dev/null 2>&1
    ok "cron enabled"
else
    skip "cron.service not found"
fi

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
PATH_FILE="/etc/systemd/system/${SERVICE_NAME}.path"

cat <<EOF | sudo tee "$SERVICE_FILE" >/dev/null
[Unit]
Description=Process always-on-claude container schedule requests
After=docker.service atd.service
Requires=docker.service atd.service

[Service]
Type=oneshot
User=$TARGET_USER
Group=$TARGET_GROUP
Environment=HOME=$TARGET_HOME
Environment=DEV_ENV=$DEV_ENV
Environment=AOC_SCHEDULE_DIR=$SCHEDULE_DIR
WorkingDirectory=$DEV_ENV
ExecStart=$DEV_ENV/scripts/runtime/process-schedule-requests.sh
EOF

cat <<EOF | sudo tee "$PATH_FILE" >/dev/null
[Unit]
Description=Watch always-on-claude container schedule request inbox

[Path]
PathExistsGlob=$SCHEDULE_DIR/inbox/*.json
Unit=${SERVICE_NAME}.service

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}.path" >/dev/null 2>&1
sudo systemctl restart "${SERVICE_NAME}.path" >/dev/null 2>&1
ok "Schedule bridge enabled"
