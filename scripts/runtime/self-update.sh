#!/bin/bash
# self-update.sh — Single command to update the entire dev environment.
#
# Updates (in order):
#   1. Dev environment repo (git pull)
#   2. Claude Code binary (inside container)
#   3. Docker image (only if Dockerfile/compose changed)
#   4. Host-side scripts (statusline, tmux config)
#   5. Reports what was updated
#
# Run manually or via the /update slash command.
# Preserves running tmux sessions — only restarts container when necessary.

set -euo pipefail

# --- Helpers ----------------------------------------------------------------

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
skip()  { echo "  SKIP: $* (already done)"; }
warn()  { echo "  WARN: $*"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

DEV_ENV="${DEV_ENV:-$HOME/dev-env}"
UPDATED=()
NEEDS_RESTART=false

# Detect workspace type
if [[ -f "$DEV_ENV/.env.workspace" ]]; then
    # shellcheck disable=SC1091
    source "$DEV_ENV/.env.workspace"
fi
WORKSPACE_TYPE="${WORKSPACE_TYPE:-ec2}"

# Build the correct docker compose command
docker_compose() {
    case "$WORKSPACE_TYPE" in
        local-mac)
            (cd "$DEV_ENV" && docker compose -f docker-compose.yml -f docker-compose.mac.yml "$@")
            ;;
        *)
            if [[ $EUID -eq 0 ]]; then
                (cd "$DEV_ENV" && docker compose "$@")
            else
                (cd "$DEV_ENV" && sudo --preserve-env=HOME docker compose "$@")
            fi
            ;;
    esac
}

docker_cmd() {
    case "$WORKSPACE_TYPE" in
        local-mac)
            docker "$@"
            ;;
        *)
            if [[ $EUID -eq 0 ]]; then
                docker "$@"
            else
                sudo docker "$@"
            fi
            ;;
    esac
}

# --- Preflight --------------------------------------------------------------

if [[ ! -d "$DEV_ENV/.git" ]]; then
    die "$DEV_ENV is not a git repo. Run install.sh first."
fi

info "Self-update starting"
echo "  Workspace type: $WORKSPACE_TYPE"
echo "  Dev env: $DEV_ENV"

# --- Step 1: Pull latest repo changes --------------------------------------

info "Step 1/5: Dev environment repo"

before=$(git -C "$DEV_ENV" rev-parse HEAD)

if git -C "$DEV_ENV" pull --ff-only 2>&1; then
    after=$(git -C "$DEV_ENV" rev-parse HEAD)
    if [[ "$before" != "$after" ]]; then
        echo ""
        echo "  Changes pulled (${before:0:7}..${after:0:7}):"
        git -C "$DEV_ENV" log --oneline "${before}..${after}" | sed 's/^/    /'
        UPDATED+=("repo: ${before:0:7}..${after:0:7}")

        # Detect what changed for smart updates
        CHANGED_FILES=$(git -C "$DEV_ENV" diff --name-only "${before}..${after}")
    else
        skip "Already up to date"
        CHANGED_FILES=""
    fi
else
    warn "git pull --ff-only failed (divergent history?). Skipping repo update."
    after="$before"
    CHANGED_FILES=""
fi

# --- Step 2: Update Claude Code binary (inside container) -------------------

info "Step 2/5: Claude Code binary"

if docker_cmd ps --format '{{.Names}}' 2>/dev/null | grep -q "claude-dev"; then
    # Get current version
    current_version=$(docker_compose exec -T dev claude --version 2>/dev/null | head -1 || echo "unknown")

    # Run the official installer inside the container
    if docker_compose exec -T dev bash -c "curl -fsSL https://claude.ai/install.sh | bash" 2>&1; then
        new_version=$(docker_compose exec -T dev claude --version 2>/dev/null | head -1 || echo "unknown")
        if [[ "$current_version" != "$new_version" ]]; then
            ok "Claude Code updated: $current_version -> $new_version"
            UPDATED+=("claude-code: $current_version -> $new_version")
        else
            skip "Claude Code already latest ($current_version)"
        fi
    else
        warn "Failed to update Claude Code inside container"
    fi
else
    warn "Container not running — skipping Claude Code update"
fi

# --- Step 3: Docker image (only if Dockerfile/compose changed) --------------

info "Step 3/5: Docker image"

IMAGE_NEEDS_UPDATE=false

if [[ -n "$CHANGED_FILES" ]]; then
    if echo "$CHANGED_FILES" | grep -qE '^(Dockerfile|docker-compose\.yml|docker-compose\.mac\.yml|docker-compose\.build\.yml)$'; then
        IMAGE_NEEDS_UPDATE=true
        echo "  Dockerfile or compose config changed — image update needed"
    fi
fi

# Also check if the remote image is newer than what we have locally
if [[ "$IMAGE_NEEDS_UPDATE" == "false" ]]; then
    IMAGE="ghcr.io/verkyyi/always-on-claude:latest"

    # Pull to check for updates (docker pull is a no-op if already latest)
    if docker_cmd pull "$IMAGE" 2>&1 | grep -q "Downloaded newer image\|Pull complete"; then
        IMAGE_NEEDS_UPDATE=true
        echo "  Newer image available from registry"
    else
        skip "Docker image already latest"
    fi
fi

if [[ "$IMAGE_NEEDS_UPDATE" == "true" ]]; then
    # Check for active Claude sessions before restarting
    active_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude-' || true)

    if [[ -n "$active_sessions" ]]; then
        echo ""
        warn "Active Claude sessions detected:"
        echo "$active_sessions" | sed 's/^/    /'
        echo ""
        echo "  The container needs to restart to apply image updates."
        echo "  Sessions will be preserved (tmux runs on the host)."
        echo ""

        if [[ -t 0 ]]; then
            read -rp "  Restart container now? [y/N] " confirm
            if [[ "$confirm" != [yY] ]]; then
                echo "  Skipping container restart. Run 'self-update.sh' again when ready."
                NEEDS_RESTART=true
            fi
        else
            # Non-interactive: skip restart, leave a flag
            NEEDS_RESTART=true
            warn "Non-interactive mode — skipping restart. Restart manually when ready."
        fi
    fi

    if [[ "$NEEDS_RESTART" == "false" ]]; then
        docker_compose up -d 2>&1
        # Fix container permissions after restart
        docker_compose exec -T -u root dev bash -c \
            "chown -R dev:dev /home/dev/projects /home/dev/.claude" 2>/dev/null || true
        # Clean up old images
        docker_cmd image prune -f 2>/dev/null || true
        ok "Container restarted with updated image"
        UPDATED+=("docker-image: updated and restarted")
    else
        UPDATED+=("docker-image: update pulled, restart pending")
    fi
fi

# --- Step 4: Host-side scripts ---------------------------------------------

info "Step 4/5: Host-side scripts"

host_updated=false

# Statusline script
if [[ -f "$DEV_ENV/scripts/runtime/statusline-command.sh" ]]; then
    if ! cmp -s "$DEV_ENV/scripts/runtime/statusline-command.sh" ~/.claude/statusline-command.sh 2>/dev/null; then
        cp "$DEV_ENV/scripts/runtime/statusline-command.sh" ~/.claude/statusline-command.sh
        chmod +x ~/.claude/statusline-command.sh
        ok "Updated statusline-command.sh"
        host_updated=true
    else
        skip "statusline-command.sh unchanged"
    fi
fi

# tmux config
if [[ -f "$DEV_ENV/scripts/runtime/tmux.conf" ]]; then
    if ! cmp -s "$DEV_ENV/scripts/runtime/tmux.conf" ~/.tmux.conf 2>/dev/null; then
        cp "$DEV_ENV/scripts/runtime/tmux.conf" ~/.tmux.conf
        ok "Updated ~/.tmux.conf"
        tmux source-file ~/.tmux.conf 2>/dev/null && ok "Reloaded tmux config" || true
        host_updated=true
    else
        skip "tmux.conf unchanged"
    fi
fi

# tmux status script
if [[ -f "$DEV_ENV/scripts/runtime/tmux-status.sh" ]]; then
    if ! cmp -s "$DEV_ENV/scripts/runtime/tmux-status.sh" ~/.tmux-status.sh 2>/dev/null; then
        cp "$DEV_ENV/scripts/runtime/tmux-status.sh" ~/.tmux-status.sh
        chmod +x ~/.tmux-status.sh
        ok "Updated ~/.tmux-status.sh"
        host_updated=true
    else
        skip "tmux-status.sh unchanged"
    fi
fi

# Make all scripts executable
chmod +x "$DEV_ENV"/scripts/deploy/*.sh "$DEV_ENV"/scripts/runtime/*.sh 2>/dev/null || true

if [[ "$host_updated" == "true" ]]; then
    UPDATED+=("host-scripts: updated")
else
    skip "All host-side scripts unchanged"
fi

# --- Step 5: Report --------------------------------------------------------

info "Step 5/5: Summary"

# Clean up the pending file if it existed
rm -f "$HOME/.update-pending"

if [[ ${#UPDATED[@]} -eq 0 ]]; then
    echo ""
    echo "  Everything is up to date. No changes applied."
    echo ""
else
    echo ""
    echo "  Updates applied:"
    for item in "${UPDATED[@]}"; do
        echo "    - $item"
    done
    echo ""
fi

if [[ "$NEEDS_RESTART" == "true" ]]; then
    echo "  NOTE: Container restart is pending. Run this script again or restart manually:"
    case "$WORKSPACE_TYPE" in
        local-mac)
            echo "    cd ~/dev-env && docker compose -f docker-compose.yml -f docker-compose.mac.yml up -d"
            ;;
        *)
            echo "    cd ~/dev-env && sudo --preserve-env=HOME docker compose up -d"
            ;;
    esac
    echo ""
fi

echo "  Done."
