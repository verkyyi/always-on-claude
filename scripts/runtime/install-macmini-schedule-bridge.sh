#!/bin/bash
# install-macmini-schedule-bridge.sh — Install the macOS schedule bridge.
#
# Runs on the Mac mini host. Container sessions write request JSON to the
# bind-mounted inbox; this LaunchAgent watches the inbox and runs the shared
# processor with macOS-specific host path and Docker settings.

set -euo pipefail

info() { printf '\n=== %s ===\n' "$*"; }
ok() { printf '  OK: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

USER_NAME="${AOC_USER:-$(id -un)}"
HOME_DIR="${AOC_HOME:-$HOME}"
REPO="${AOC_REPO:-$HOME_DIR/always-on-claude}"
SCHEDULE_DIR="${AOC_SCHEDULE_DIR:-$HOME_DIR/.always-on-claude/schedule}"
PROJECTS_DIR="${AOC_HOST_PROJECTS_DIR:-$HOME_DIR/projects}"
DOCKER="${AOC_DOCKER:-/opt/homebrew/bin/docker}"
COMPOSE_FILE="${AOC_DOCKER_COMPOSE_FILE:-docker-compose.macmini.yml}"
LABEL="com.always-on-claude.schedule-bridge"
PLIST="$HOME_DIR/Library/LaunchAgents/$LABEL.plist"
PROCESSOR="$REPO/scripts/runtime/process-schedule-requests.sh"
LOG_FILE="$SCHEDULE_DIR/logs/launchd.log"

command -v launchctl >/dev/null 2>&1 || die "launchctl is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
[ -x "$DOCKER" ] || die "Docker not found at $DOCKER"
[ -x "$PROCESSOR" ] || die "Missing executable processor: $PROCESSOR"
[ -f "$REPO/$COMPOSE_FILE" ] || die "Missing compose file: $REPO/$COMPOSE_FILE"

info "Schedule bridge directories"
for dir in inbox processing jobs logs status; do
    mkdir -p "$SCHEDULE_DIR/$dir"
done
mkdir -p "$PROJECTS_DIR" "$HOME_DIR/Library/LaunchAgents"
chmod 700 "$SCHEDULE_DIR" "$SCHEDULE_DIR/inbox" "$SCHEDULE_DIR/processing" "$SCHEDULE_DIR/jobs"
chmod 755 "$SCHEDULE_DIR/logs" "$SCHEDULE_DIR/status"
ok "Directories ready"

info "LaunchAgent"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$PROCESSOR</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME_DIR</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>AOC_USER</key>
    <string>$USER_NAME</string>
    <key>DEV_ENV</key>
    <string>$REPO</string>
    <key>AOC_SCHEDULE_DIR</key>
    <string>$SCHEDULE_DIR</string>
    <key>AOC_DOCKER</key>
    <string>$DOCKER</string>
    <key>AOC_DOCKER_COMPOSE_FILE</key>
    <string>$COMPOSE_FILE</string>
    <key>AOC_DOCKER_SERVICE</key>
    <string>dev</string>
    <key>AOC_DOCKER_EXEC_PREFIX</key>
    <string></string>
    <key>AOC_CONTAINER_PROJECTS_DIR</key>
    <string>/home/dev/projects</string>
    <key>AOC_HOST_PROJECTS_DIR</key>
    <string>$PROJECTS_DIR</string>
    <key>AOC_AT_BACKEND</key>
    <string>launchd</string>
    <key>AOC_CRON_BACKEND</key>
    <string>launchd</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>AbandonProcessGroup</key>
  <true/>
  <key>WatchPaths</key>
  <array>
    <string>$SCHEDULE_DIR/inbox</string>
  </array>
  <key>StandardOutPath</key>
  <string>$LOG_FILE</string>
  <key>StandardErrorPath</key>
  <string>$LOG_FILE</string>
</dict>
</plist>
PLIST
chmod 644 "$PLIST"
plutil -lint "$PLIST" >/dev/null
ok "Wrote $PLIST"

launchctl unload "$PLIST" >/dev/null 2>&1 || true
launchctl load -w "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || launchctl start "$LABEL" >/dev/null 2>&1 || true
ok "LaunchAgent loaded"

info "Existing recurring jobs"
AOC_USER="$USER_NAME" \
DEV_ENV="$REPO" \
AOC_SCHEDULE_DIR="$SCHEDULE_DIR" \
AOC_DOCKER="$DOCKER" \
AOC_DOCKER_COMPOSE_FILE="$COMPOSE_FILE" \
AOC_DOCKER_SERVICE="dev" \
AOC_DOCKER_EXEC_PREFIX="" \
AOC_CONTAINER_PROJECTS_DIR="/home/dev/projects" \
AOC_HOST_PROJECTS_DIR="$PROJECTS_DIR" \
AOC_AT_BACKEND="launchd" \
AOC_CRON_BACKEND="launchd" \
    "$PROCESSOR" --reinstall-cron
ok "Recurring jobs reconciled"

info "Process pending requests"
AOC_USER="$USER_NAME" \
DEV_ENV="$REPO" \
AOC_SCHEDULE_DIR="$SCHEDULE_DIR" \
AOC_DOCKER="$DOCKER" \
AOC_DOCKER_COMPOSE_FILE="$COMPOSE_FILE" \
AOC_DOCKER_SERVICE="dev" \
AOC_DOCKER_EXEC_PREFIX="" \
AOC_CONTAINER_PROJECTS_DIR="/home/dev/projects" \
AOC_HOST_PROJECTS_DIR="$PROJECTS_DIR" \
AOC_AT_BACKEND="launchd" \
AOC_CRON_BACKEND="launchd" \
    "$PROCESSOR"
ok "Schedule bridge ready"
