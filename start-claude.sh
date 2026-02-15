#!/bin/bash
# start-claude.sh — Auto-starts the dev container if needed,
# then enters it and launches Claude Code inside tmux.
#
# Called automatically from .bash_profile on SSH login.

set -euo pipefail

COMPOSE_DIR="$HOME/dev-env"
CONTAINER_NAME="claude-dev"

# Start container if not running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container not running. Starting..."
    cd "$COMPOSE_DIR" && docker compose up -d
    sleep 2

    # Fix volume permissions on fresh start
    docker compose exec -u root dev bash -c \
        "chown -R dev:dev /home/dev/.claude /home/dev/project" 2>/dev/null || true
fi

# Attach to existing tmux session, or create one running Claude Code
exec tmux new-session -A -s claude \
    "docker exec -it ${CONTAINER_NAME} bash -lc 'claude'"
