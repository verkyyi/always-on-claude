#!/bin/bash
# update.sh — Check for available updates (fetch only, never pull).
#
# This script only checks if the remote has new commits. It does NOT
# apply changes — that's done by self-update.sh via the /update slash
# command. This keeps the workspace static until the user explicitly
# triggers an update.
#
# Run by systemd timer every 6 hours, or manually.

set -euo pipefail

DEV_ENV="${DEV_ENV:-$HOME/dev-env}"

# Load config if available
if [[ -f "$DEV_ENV/scripts/deploy/load-config.sh" ]]; then
    # shellcheck disable=SC1091
    source "$DEV_ENV/scripts/deploy/load-config.sh"
fi

PENDING_FILE="$HOME/.update-pending"
LOG_FILE="$DEV_ENV/update.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

if [[ ! -d "$DEV_ENV/.git" ]]; then
    log "ERROR: $DEV_ENV is not a git repo"
    exit 1
fi

# Fetch latest without applying
if ! git -C "$DEV_ENV" fetch --quiet >> "$LOG_FILE" 2>&1; then
    log "ERROR: git fetch failed"
    exit 1
fi

local_head=$(git -C "$DEV_ENV" rev-parse HEAD)
remote_head=$(git -C "$DEV_ENV" rev-parse '@{upstream}' 2>/dev/null || echo "$local_head")

if [[ "$local_head" == "$remote_head" ]]; then
    log "No updates available"
    rm -f "$PENDING_FILE"
else
    # Check if the update includes Dockerfile or compose changes
    needs_rebuild=false
    if git -C "$DEV_ENV" diff --name-only "${local_head}..${remote_head}" | grep -qE '^(Dockerfile|docker-compose)'; then
        needs_rebuild=true
    fi

    # Write pending file with details (no changes applied yet)
    {
        echo "updated=$(date -Iseconds)"
        echo "before=$local_head"
        echo "after=$remote_head"
        echo "needs_rebuild=$needs_rebuild"
        git -C "$DEV_ENV" log --oneline "${local_head}..${remote_head}"
    } > "$PENDING_FILE"

    log "Updates available: ${local_head:0:7}..${remote_head:0:7} (rebuild=$needs_rebuild) — run /update to apply"
fi
