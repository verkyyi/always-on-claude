#!/bin/bash
# autostart-mac.sh — Install launchd agent to auto-start the Docker container on login.
#
# Creates a user-level LaunchAgent that runs docker compose up -d at login.
# Idempotent — safe to re-run.

set -euo pipefail

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }

LABEL="com.always-on-claude.container"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
DEV_ENV="${DEV_ENV:-$HOME/dev-env}"

info "Container auto-start (launchd agent)"

mkdir -p "$HOME/Library/LaunchAgents"

# Find docker compose — could be in Homebrew or Docker Desktop paths
DOCKER_BIN=$(command -v docker 2>/dev/null || echo "/usr/local/bin/docker")

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${DOCKER_BIN}</string>
        <string>compose</string>
        <string>-f</string>
        <string>${DEV_ENV}/docker-compose.yml</string>
        <string>-f</string>
        <string>${DEV_ENV}/docker-compose.mac.yml</string>
        <string>up</string>
        <string>-d</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${HOME}/.claude/container-start.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/.claude/container-start.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>${DEV_ENV}</string>
</dict>
</plist>
EOF

# Unload first if already loaded (idempotent)
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

ok "Launchd agent installed and loaded (runs at login)"
