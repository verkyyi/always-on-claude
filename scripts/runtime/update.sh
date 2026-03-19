#!/bin/bash
# update.sh — Lightweight updater that pulls latest repo changes.
#
# This script only pulls code. It does NOT apply changes — that's
# orchestrated by Claude via the /update slash command.
#
# Run by systemd timer every 6 hours, or manually.

set -euo pipefail

DEV_ENV="$HOME/dev-env"
PENDING_FILE="$HOME/.update-pending"
LOG_FILE="$DEV_ENV/update.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

if [[ ! -d "$DEV_ENV/.git" ]]; then
    log "ERROR: $DEV_ENV is not a git repo"
    exit 1
fi

# Record current commit before pull
before=$(git -C "$DEV_ENV" rev-parse HEAD)

# Pull latest
if ! git -C "$DEV_ENV" pull --ff-only >> "$LOG_FILE" 2>&1; then
    log "ERROR: git pull --ff-only failed (divergent history?)"
    exit 1
fi

after=$(git -C "$DEV_ENV" rev-parse HEAD)

if [[ "$before" == "$after" ]]; then
    log "No updates available"
    exit 0
fi

# New commits pulled — write pending file with details
{
    echo "updated=$(date -Iseconds)"
    echo "before=$before"
    echo "after=$after"
    git -C "$DEV_ENV" log --oneline "${before}..${after}"
} > "$PENDING_FILE"

log "Updates pulled: ${before:0:7}..${after:0:7} — pending /update"
