#!/bin/bash
# rolling-update.sh — Zero-downtime workspace updates.
#
# Pulls the latest repo changes and applies them without interrupting
# active Claude Code sessions. Image updates wait for sessions to finish
# (or use --force to skip).
#
# Usage:
#   rolling-update.sh              # Interactive: warns and waits
#   rolling-update.sh --force      # Skip active session checks
#   rolling-update.sh --check      # Dry run: show what would change
#
# Called by systemd timer, or manually.

set -euo pipefail

DEV_ENV="${DEV_ENV:-$HOME/dev-env}"
PENDING_FILE="$HOME/.update-pending"
LOG_FILE="$DEV_ENV/update.log"
CONTAINER_NAME="claude-dev"

# Defaults
FORCE=false
CHECK_ONLY=false
WAIT_TIMEOUT=300  # 5 minutes max wait for sessions to end

# Parse flags
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --check) CHECK_ONLY=true ;;
        --timeout=*) WAIT_TIMEOUT="${arg#--timeout=}" ;;
        *) ;;
    esac
done

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
warn()  { echo "  WARN: $*"; }
skip()  { echo "  SKIP: $* (already done)"; }
die()   { echo "ERROR: $*" >&2; exit 1; }
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

COMPOSE_CMD="sudo --preserve-env=HOME docker compose"

# --- Active session detection ---

# List active Claude Code tmux sessions
list_active_sessions() {
    tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep '^claude-' || true
}

# Count active sessions
count_active_sessions() {
    local sessions
    sessions=$(list_active_sessions)
    if [[ -z "$sessions" ]]; then
        echo 0
    else
        echo "$sessions" | wc -l | tr -d ' '
    fi
}

# Check if any Claude Code process is actively running inside the container
has_active_claude_processes() {
    docker exec "$CONTAINER_NAME" pgrep -f "claude" &>/dev/null 2>&1
}

# --- Git operations ---

pull_latest() {
    if [[ ! -d "$DEV_ENV/.git" ]]; then
        die "$DEV_ENV is not a git repo"
    fi

    local before after
    before=$(git -C "$DEV_ENV" rev-parse HEAD)

    if ! git -C "$DEV_ENV" pull --ff-only >> "$LOG_FILE" 2>&1; then
        die "git pull --ff-only failed (divergent history?)"
    fi

    after=$(git -C "$DEV_ENV" rev-parse HEAD)

    if [[ "$before" == "$after" ]]; then
        echo "NO_CHANGES"
        return
    fi

    # Preserve any existing restart_pending marker before overwriting
    local existing_restart=""
    if [[ -f "$PENDING_FILE" ]] && grep -q "restart_pending=" "$PENDING_FILE" 2>/dev/null; then
        existing_restart=$(grep "restart_pending=" "$PENDING_FILE")
    fi

    # Write pending file
    {
        echo "updated=$(date -Iseconds)"
        echo "before=$before"
        echo "after=$after"
        git -C "$DEV_ENV" log --oneline "${before}..${after}"
        if [[ -n "$existing_restart" ]]; then
            echo "$existing_restart"
        fi
    } > "$PENDING_FILE"

    echo "${before}..${after}"
}

# Classify changed files into categories
classify_changes() {
    local range="$1"
    local changed_files
    changed_files=$(git -C "$DEV_ENV" diff --name-only "$range")

    local needs_image_update=false
    local needs_compose_restart=false
    local needs_statusline_copy=false
    local scripts_updated=false
    local commands_updated=false
    local docs_only=true

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        case "$file" in
            Dockerfile)
                needs_image_update=true
                docs_only=false
                ;;
            docker-compose*.yml)
                needs_compose_restart=true
                docs_only=false
                ;;
            scripts/runtime/statusline-command.sh)
                needs_statusline_copy=true
                docs_only=false
                ;;
            scripts/runtime/*|scripts/deploy/*)
                scripts_updated=true
                docs_only=false
                ;;
            .claude/commands/*)
                commands_updated=true
                docs_only=false
                ;;
            .github/*)
                ;; # CI changes, no action needed
            *.md)
                ;; # docs only
            *)
                docs_only=false
                ;;
        esac
    done <<< "$changed_files"

    # Output classification as key=value pairs
    echo "needs_image_update=$needs_image_update"
    echo "needs_compose_restart=$needs_compose_restart"
    echo "needs_statusline_copy=$needs_statusline_copy"
    echo "scripts_updated=$scripts_updated"
    echo "commands_updated=$commands_updated"
    echo "docs_only=$docs_only"
}

# --- Update application ---

apply_statusline() {
    info "Statusline update"
    cp "$DEV_ENV/scripts/runtime/statusline-command.sh" "$HOME/.claude/statusline-command.sh"
    chmod +x "$HOME/.claude/statusline-command.sh"
    ok "Statusline script updated"
}

apply_image_update() {
    info "Image update"

    # Pull new image
    cd "$DEV_ENV"
    if ! eval "$COMPOSE_CMD pull" >> "$LOG_FILE" 2>&1; then
        warn "Image pull failed — see $LOG_FILE"
        return 1
    fi
    ok "New image pulled"

    # Check for active sessions
    local session_count
    session_count=$(count_active_sessions)

    if [[ "$session_count" -gt 0 ]] && [[ "$FORCE" != "true" ]]; then
        warn "$session_count active Claude session(s) detected"
        list_active_sessions | while read -r s; do
            echo "    - $s"
        done

        # In non-interactive (timer) mode, defer restart
        if [[ ! -t 0 ]]; then
            warn "Deferring container restart — active sessions running"
            warn "Image is pulled and ready. Restart will happen when sessions end."
            log "Image pulled but restart deferred — $session_count active sessions"

            # Write a restart-pending marker
            echo "restart_pending=$(date -Iseconds)" >> "$PENDING_FILE"
            return 0
        fi

        # Interactive mode: wait for sessions to finish
        echo ""
        echo "  Waiting up to ${WAIT_TIMEOUT}s for sessions to end..."
        echo "  (Ctrl-C to cancel, or re-run with --force to restart immediately)"
        echo ""

        local elapsed=0
        while [[ $elapsed -lt $WAIT_TIMEOUT ]]; do
            session_count=$(count_active_sessions)
            if [[ "$session_count" -eq 0 ]]; then
                ok "All sessions ended"
                break
            fi
            sleep 10
            elapsed=$((elapsed + 10))
            echo "  ... $session_count session(s) still active (${elapsed}s / ${WAIT_TIMEOUT}s)"
        done

        session_count=$(count_active_sessions)
        if [[ "$session_count" -gt 0 ]]; then
            warn "Timeout reached with $session_count active session(s)"
            warn "Skipping container restart. Run with --force to override."
            echo "restart_pending=$(date -Iseconds)" >> "$PENDING_FILE"
            return 0
        fi
    fi

    restart_container
}

restart_container() {
    info "Container restart"

    cd "$DEV_ENV"

    # Use stop/start if no image change needs down/up
    # For image updates, we need down/up (or up -d which handles it)
    eval "$COMPOSE_CMD up -d" >> "$LOG_FILE" 2>&1

    # Fix permissions
    eval "$COMPOSE_CMD exec -T -u root dev bash -c 'chown -R dev:dev /home/dev/projects /home/dev/.claude'" 2>/dev/null || true

    # Prune old images
    sudo docker image prune -f >> "$LOG_FILE" 2>&1

    ok "Container restarted with new image"
    log "Container restarted successfully"
}

# --- Check for deferred restart ---

check_deferred_restart() {
    if [[ ! -f "$PENDING_FILE" ]]; then
        return 1
    fi

    if grep -q "restart_pending=" "$PENDING_FILE" 2>/dev/null; then
        local session_count
        session_count=$(count_active_sessions)

        if [[ "$session_count" -eq 0 ]]; then
            info "Applying deferred restart"
            ok "No active sessions — safe to restart"
            restart_container

            # Remove the restart_pending line
            local tmp
            tmp=$(grep -v "restart_pending=" "$PENDING_FILE")
            if [[ -n "$tmp" ]]; then
                echo "$tmp" > "$PENDING_FILE"
            else
                rm -f "$PENDING_FILE"
            fi
            return 0
        else
            log "Deferred restart still waiting — $session_count active sessions"
            return 1
        fi
    fi
    return 1
}

# --- Main ---

info "Rolling update"

# First, check for any deferred restart from a previous run
if check_deferred_restart; then
    ok "Deferred restart applied"
    # Continue to check for new updates
fi

# Pull latest changes
result=$(pull_latest)

if [[ "$result" == "NO_CHANGES" ]]; then
    ok "Already up to date"
    log "No updates available"
    if ! grep -q "restart_pending=" "$PENDING_FILE" 2>/dev/null; then
        rm -f "$PENDING_FILE"
    fi
    exit 0
fi

range="$result"
info "Changes detected: $range"

# Show what changed
git -C "$DEV_ENV" log --oneline "$range"
echo ""

# Classify changes
while IFS='=' read -r key val; do
    declare "$key=$val"
done < <(classify_changes "$range")

if [[ "$CHECK_ONLY" == "true" ]]; then
    info "Dry run — changes detected"
    echo "  needs_image_update=$needs_image_update"
    echo "  needs_compose_restart=$needs_compose_restart"
    echo "  needs_statusline_copy=$needs_statusline_copy"
    echo "  scripts_updated=$scripts_updated"
    echo "  commands_updated=$commands_updated"
    echo "  docs_only=$docs_only"
    echo "  active_sessions=$(count_active_sessions)"
    exit 0
fi

# Apply updates based on classification

if [[ "$docs_only" == "true" ]]; then
    ok "Documentation-only changes — no action needed"
    rm -f "$PENDING_FILE"
    log "Docs-only update applied: $range"
    exit 0
fi

if [[ "$scripts_updated" == "true" ]]; then
    ok "Runtime scripts updated (live via bind mount — no restart needed)"
fi

if [[ "$commands_updated" == "true" ]]; then
    ok "Slash commands updated (live via bind mount — no restart needed)"
fi

if [[ "$needs_statusline_copy" == "true" ]]; then
    apply_statusline
fi

if [[ "$needs_image_update" == "true" ]] || [[ "$needs_compose_restart" == "true" ]]; then
    apply_image_update
else
    ok "No container restart required"
fi

# Clean up pending file (unless a restart is deferred)
if ! grep -q "restart_pending=" "$PENDING_FILE" 2>/dev/null; then
    rm -f "$PENDING_FILE"
fi

log "Rolling update complete: $range"
info "Update complete"
