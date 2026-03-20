#!/bin/bash
# install-updater-mac.sh — Install launchd agent for periodic repo updates on macOS.
#
# Creates a user-level LaunchAgent that runs update.sh every 6 hours.
# Idempotent — safe to re-run.

set -euo pipefail

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }

LABEL="com.always-on-claude.update"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
DEV_ENV="${DEV_ENV:-$HOME/dev-env}"

info "Auto-updater (launchd agent)"

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${DEV_ENV}/scripts/runtime/update.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>21600</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${HOME}/.claude/update.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/.claude/update.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
EOF

# Unload first if already loaded (idempotent)
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

ok "Launchd agent installed and loaded (every 6 hours)"
