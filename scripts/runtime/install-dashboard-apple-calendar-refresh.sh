#!/usr/bin/env bash

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$LAUNCH_AGENTS_DIR/com.always-on-claude.dashboard-apple-calendar-refresh.plist"
LABEL="com.always-on-claude.dashboard-apple-calendar-refresh"
SCRIPT="$REPO/scripts/runtime/dashboard-apple-calendar-refresh.sh"

mkdir -p "$LAUNCH_AGENTS_DIR"

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>$SCRIPT</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>WorkingDirectory</key>
    <string>$HOME/projects/dashboard</string>
    <key>StandardOutPath</key>
    <string>$HOME/.always-on-claude/schedule/logs/apple-calendar-host.launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.always-on-claude/schedule/logs/apple-calendar-host.launchd.log</string>
  </dict>
</plist>
EOF

mkdir -p "$HOME/.always-on-claude/schedule/logs"
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/$LABEL"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
