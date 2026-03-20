#!/bin/bash
# onboarding.sh — Guided first-run setup via Claude Code.
# Launches a Claude session with a specialized onboarding prompt that walks
# the user through git config, GitHub auth, cloning their first repo, and
# a quick tour of the workspace.
#
# Called from ssh-login.sh when ~/.workspace-initialized doesn't exist.
# Creates ~/.workspace-initialized when complete.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

COMPOSE_DIR="$HOME/dev-env"
CONTAINER_NAME="claude-dev"
ONBOARDING_PROMPT="$COMPOSE_DIR/scripts/runtime/onboarding-prompt.txt"

[[ -f "$ONBOARDING_PROMPT" ]] || die "Onboarding prompt not found: $ONBOARDING_PROMPT"

# Start container if not running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "  Starting container..."
    (cd "$COMPOSE_DIR" && docker compose up -d)

    # Wait for container to be ready (up to 30s)
    for i in $(seq 1 30); do
        if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            break
        fi
        if [[ $i -eq 30 ]]; then
            die "Container failed to start within 30s"
        fi
        sleep 1
    done

    docker exec -u root "$CONTAINER_NAME" bash -c \
        "chown -R dev:dev /home/dev/projects" 2>/dev/null || true
fi

echo ""
echo "  First-time setup — Claude will walk you through it."
echo ""

exec tmux new-session -A -s "claude-onboarding" \
    "bash -lc 'cd \"$COMPOSE_DIR\" && exec claude --append-system-prompt-file \"$ONBOARDING_PROMPT\" \"This is my first time here. Help me get set up.\"'"
