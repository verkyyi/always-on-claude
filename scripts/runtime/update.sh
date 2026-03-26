#!/bin/bash
# update.sh — Lightweight updater that pulls latest repo changes.
#
# This script only pulls code. It does NOT apply changes — that's
# orchestrated by Claude via the /update slash command.
#
# When updates include Dockerfile/compose changes (which require a
# container rebuild), a pre-update backup is taken automatically
# via backup-state.sh.
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
BACKUP_SCRIPT="$DEV_ENV/scripts/runtime/backup-state.sh"

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
else
    # Check if the update includes Dockerfile or compose changes (needs rebuild)
    needs_rebuild=false
    if git -C "$DEV_ENV" diff --name-only "${before}..${after}" | grep -qE '^(Dockerfile|docker-compose)'; then
        needs_rebuild=true
    fi

    # Auto-backup when updates require a container rebuild
    if [[ "$needs_rebuild" == "true" && -x "$BACKUP_SCRIPT" ]]; then
        log "Container rebuild needed — running pre-update backup"
        bash "$BACKUP_SCRIPT" >> "$LOG_FILE" 2>&1 || log "WARN: backup-state.sh failed (continuing)"
    fi

    # New commits pulled — write pending file with details
    {
        echo "updated=$(date -Iseconds)"
        echo "before=$before"
        echo "after=$after"
        echo "needs_rebuild=$needs_rebuild"
        echo "backup_dir=$HOME/backups/latest"
        git -C "$DEV_ENV" log --oneline "${before}..${after}"
    } > "$PENDING_FILE"

    log "Updates pulled: ${before:0:7}..${after:0:7} (rebuild=$needs_rebuild) — pending /update"
fi

# Check for Claude Code binary updates
if [[ -x "$DEV_ENV/scripts/runtime/check-claude-version.sh" ]]; then
    bash "$DEV_ENV/scripts/runtime/check-claude-version.sh" || true
fi
