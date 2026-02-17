#!/bin/bash
# start-claude.sh — Auto-starts the dev container if needed,
# then presents a workspace picker and launches Claude Code
# inside a named tmux session.
#
# Called automatically from ssh-login.sh on SSH login.

set -euo pipefail

COMPOSE_DIR="$HOME/dev-env"
CONTAINER_NAME="claude-dev"

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container not running. Starting..."
    cd "$COMPOSE_DIR" && docker compose up -d
    sleep 2

    # Fix named volume permissions (projects dir mounts as root)
    # ~/.claude is a bind mount — inherits host ownership, no fix needed
    docker compose exec -u root dev bash -c \
        "chown -R dev:dev /home/dev/projects" 2>/dev/null || true
fi

# Discover git repos inside the container
mapfile -t repos < <(
    docker exec "$CONTAINER_NAME" bash -c \
        'find /home/dev -maxdepth 3 -name .git -type d 2>/dev/null | sort' \
    | sed 's|/\.git$||' | sed 's|^/home/dev/||'
)

# Build workspace menu
echo ""
echo "  ┌─────────────────────────────┐"
echo "  │  Pick workspace:            │"

i=1
for repo in "${repos[@]}"; do
    label="  │  [$i] $repo"
    printf "%-33s│\n" "$label"
    ((i++))
done

home_idx=$i
printf "%-33s│\n" "  │  [$home_idx] ~ (home)"
echo "  └─────────────────────────────┘"
echo ""

choice=""
read -n 1 -p "  > " choice || true
echo ""

# Map choice to directory
if [[ -n "$choice" && "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#repos[@]}" ]]; then
    selected="/home/dev/${repos[$((choice - 1))]}"
elif [[ "$choice" == "$home_idx" ]]; then
    selected="/home/dev"
else
    # Default: first repo, or home if none found
    if [[ ${#repos[@]} -gt 0 ]]; then
        selected="/home/dev/${repos[0]}"
    else
        selected="/home/dev"
    fi
fi

echo "  → $selected"
echo ""

# Create unique tmux session name based on chosen directory
session_name="claude-$(basename "$selected")"

exec tmux new-session -A -s "$session_name" \
    "docker exec -it -w '$selected' ${CONTAINER_NAME} bash -lc 'exec claude'"
