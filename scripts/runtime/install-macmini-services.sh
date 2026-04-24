#!/bin/bash
# install-macmini-services.sh — Install Mac mini host services.

set -euo pipefail

REPO="${AOC_REPO:-$HOME/always-on-claude}"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

disable_legacy_agent() {
    local label="$1"
    local plist="$LAUNCH_AGENTS_DIR/$label.plist"
    local disabled="$plist.disabled"

    [[ -f "$plist" ]] || return 0

    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || \
        launchctl unload "$plist" >/dev/null 2>&1 || true
    mv "$plist" "$disabled"
    printf '  OK: Disabled legacy LaunchAgent %s\n' "$label"
}

printf '\n=== Legacy Mac launch agents ===\n'
disable_legacy_agent "com.always-on-claude.container"
disable_legacy_agent "com.always-on-claude.update"

bash "$REPO/scripts/runtime/install-macmini-host-tools.sh"
bash "$REPO/scripts/runtime/install-macmini-schedule-bridge.sh"
bash "$REPO/scripts/runtime/install-macmini-nginx.sh"
