#!/bin/bash
# check-claude-version.sh — Check if a newer Claude Code version is available.
#
# Compares the installed version against the latest from npm registry.
# Writes results to ~/.claude-version-check for display at SSH login.
# Optionally auto-updates if CLAUDE_AUTO_UPDATE=1.
#
# Run by update.sh (via systemd/launchd timer) or manually.
# Runs inside the container where Claude Code is installed.

set -euo pipefail

STATE_FILE="$HOME/.claude-version-check"
LOG_FILE="$HOME/.claude/claude-updates.log"
CONTAINER_NAME="claude-dev"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# --- Get installed version ---

installed=""
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    installed=$(docker exec "$CONTAINER_NAME" claude --version 2>/dev/null || true)
fi

# Fallback: check host claude if container version unavailable
if [[ -z "$installed" ]] && command -v claude &>/dev/null; then
    installed=$(claude --version 2>/dev/null || true)
fi

if [[ -z "$installed" ]]; then
    log "WARN: Could not determine installed Claude Code version"
    exit 0
fi

# Extract bare semver — `claude --version` outputs "2.1.80 (Claude Code)"
installed=$(echo "$installed" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

if [[ -z "$installed" ]]; then
    log "WARN: Could not parse semver from Claude Code version output"
    exit 0
fi

# --- Get latest version from npm ---

latest=$(curl -sS --max-time 10 "https://registry.npmjs.org/@anthropic-ai/claude-code/latest" 2>/dev/null \
    | jq -r '.version // empty' 2>/dev/null || true)

if [[ -z "$latest" ]]; then
    log "WARN: Could not fetch latest Claude Code version from npm"
    exit 0
fi

# --- Compare versions ---

log "Version check: installed=$installed latest=$latest"

if [[ "$installed" == "$latest" ]]; then
    # Up to date — write state file so login knows to stay quiet
    {
        echo "status=current"
        echo "installed=$installed"
        echo "latest=$latest"
        echo "checked=$(date -Iseconds)"
    } > "$STATE_FILE"
    exit 0
fi

# Newer version available — write state file for login notification
{
    echo "status=update-available"
    echo "installed=$installed"
    echo "latest=$latest"
    echo "checked=$(date -Iseconds)"
} > "$STATE_FILE"

log "Update available: $installed -> $latest"

# --- Auto-update if configured ---

if [[ "${CLAUDE_AUTO_UPDATE:-0}" == "1" ]]; then
    log "Auto-update enabled, updating Claude Code $installed -> $latest"

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        if docker exec -u dev "$CONTAINER_NAME" bash -c 'curl -fsSL https://claude.ai/install.sh | bash' 2>>"$LOG_FILE"; then
            log "Auto-update successful: now at $latest"
            {
                echo "status=current"
                echo "installed=$latest"
                echo "latest=$latest"
                echo "checked=$(date -Iseconds)"
                echo "auto_updated=$(date -Iseconds)"
            } > "$STATE_FILE"
        else
            log "ERROR: Auto-update failed"
        fi
    else
        log "WARN: Container not running, skipping auto-update"
    fi
fi
