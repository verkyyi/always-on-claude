#!/bin/bash
# self-update.sh — Single command to update the entire dev environment.
#
# Updates (in order):
#   1. Dev environment repo (git pull)
#   2. Docker image (only if Dockerfile/compose changed)
#   3. Host-side scripts (statusline, tmux config)
#   4. Reports what was updated
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

# Build the correct docker compose command
docker_compose() {
    if [[ $EUID -eq 0 ]]; then
        (cd "$DEV_ENV" && docker compose "$@")
    else
        (cd "$DEV_ENV" && sudo --preserve-env=HOME docker compose "$@")
    fi
}

docker_cmd() {
    if [[ $EUID -eq 0 ]]; then
        docker "$@"
    else
        sudo docker "$@"
    fi
}

# --- Preflight --------------------------------------------------------------

if [[ ! -d "$DEV_ENV/.git" ]]; then
    die "$DEV_ENV is not a git repo. Run install.sh first."
fi

info "Self-update starting"
echo "  Dev env: $DEV_ENV"

# --- Step 1: Pull latest repo changes --------------------------------------

info "Step 1/4: Dev environment repo"

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

# --- Step 2: Docker image (only if Dockerfile/compose changed) --------------

info "Step 2/4: Docker image"

IMAGE_NEEDS_UPDATE=false
IMAGE="ghcr.io/verkyyi/always-on-claude:latest"

if [[ -n "$CHANGED_FILES" ]]; then
    if echo "$CHANGED_FILES" | grep -qE '^(Dockerfile|docker-compose\.yml|docker-compose\.build\.yml)$'; then
        IMAGE_NEEDS_UPDATE=true
        echo "  Dockerfile or compose config changed — image update needed"
    fi
fi

# Always pull the latest image to check for updates
# Compare image digests before and after pull to detect genuine updates
local_digest_before=$(docker_cmd inspect --format='{{.Id}}' "$IMAGE" 2>/dev/null || echo "none")
echo "  Pulling latest image..."
docker_cmd pull "$IMAGE" 2>&1
local_digest_after=$(docker_cmd inspect --format='{{.Id}}' "$IMAGE" 2>/dev/null || echo "none")

if [[ "$IMAGE_NEEDS_UPDATE" == "false" ]]; then
    # No Dockerfile/compose changes — check if the remote image is newer
    if [[ "$local_digest_before" != "$local_digest_after" ]]; then
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
        while IFS= read -r session; do echo "    $session"; done <<< "$active_sessions"
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

# --- Step 3: Host-side scripts ---------------------------------------------

info "Step 3/4: Host-side scripts"

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

# --- Step 4: Report --------------------------------------------------------

info "Step 4/4: Summary"

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
    echo "    cd ~/dev-env && sudo --preserve-env=HOME docker compose up -d"
    echo ""
fi

echo "  Done."
