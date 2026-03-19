#!/bin/bash
# start-claude.sh — Auto-starts the dev container if needed,
# then presents a workspace picker and launches Claude Code
# inside a named tmux session.
#
# Called automatically from ssh-login.sh on SSH login.
# Worktree create/delete is handled by the /workspace slash command
# inside Claude Code — this script only does selection.

set -euo pipefail

COMPOSE_DIR="$HOME/dev-env"
CONTAINER_NAME="claude-dev"

# Start container if not running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container not running. Starting..."
    cd "$COMPOSE_DIR" && docker compose up -d
    sleep 2
    docker compose exec -u root dev bash -c \
        "chown -R dev:dev /home/dev/projects" 2>/dev/null || true
fi

show_menu() {
    # Show active claude-* tmux sessions
    local sessions
    sessions=$(tmux list-sessions -F '#{session_name} #{?session_attached,(attached),(idle)}' 2>/dev/null \
        | grep '^claude-' || true)

    if [[ -n "$sessions" ]]; then
        echo ""
        echo "  === Active sessions ==="
        while IFS= read -r line; do
            echo "  $line"
        done <<< "$sessions"
    fi

    # Discover repos and worktrees via worktree-helper.sh
    mapfile -t entries < <(
        docker exec "$CONTAINER_NAME" bash -c \
            'bash /home/dev/dev-env/scripts/runtime/worktree-helper.sh list-repos 2>/dev/null' \
        | sort
    )

    repos=()
    worktrees=()
    for entry in "${entries[@]}"; do
        IFS='|' read -r kind path branch <<< "$entry"
        case "$kind" in
            REPO)     repos+=("$path|$branch") ;;
            WORKTREE) worktrees+=("$path|$branch") ;;
        esac
    done

    # Build combined list (repos first, then worktrees)
    all=()
    for item in "${repos[@]+"${repos[@]}"}"; do all+=("$item"); done
    for item in "${worktrees[@]+"${worktrees[@]}"}"; do all+=("WT:$item"); done

    echo ""
    echo "  === Workspaces ==="
    local i=1
    for item in "${all[@]}"; do
        local display_path display_branch suffix=""
        if [[ "$item" == WT:* ]]; then
            item="${item#WT:}"
            suffix=" (worktree)"
        fi
        IFS='|' read -r display_path display_branch <<< "$item"
        local short_path="${display_path#/home/dev/}"
        echo "  [$i] ${short_path} (${display_branch})${suffix}"
        ((i++))
    done

    echo "  [h] ~ (home)"
    echo "  [r] Refresh list"
    echo ""
}

show_menu

while true; do
    read -n 1 -p "  > " choice || true
    echo ""

    # Flat list for index lookup
    all_flat=()
    for item in "${repos[@]+"${repos[@]}"}"; do all_flat+=("$item"); done
    for item in "${worktrees[@]+"${worktrees[@]}"}"; do all_flat+=("$item"); done

    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#all_flat[@]}" ]]; then
        IFS='|' read -r selected _ <<< "${all_flat[$((choice - 1))]}"
        break
    elif [[ "$choice" == "h" ]]; then
        selected="/home/dev"
        break
    elif [[ "$choice" == "r" ]]; then
        show_menu
        continue
    else
        # Default: first repo, or home if none found
        if [[ ${#all_flat[@]} -gt 0 ]]; then
            IFS='|' read -r selected _ <<< "${all_flat[0]}"
        else
            selected="/home/dev"
        fi
        break
    fi
done

echo "  -> $selected"
echo ""

# Create unique tmux session name — sanitize dots/colons/slashes for tmux
session_name="claude-$(basename "$selected" | tr './:' '-')"

exec tmux new-session -A -s "$session_name" \
    "docker exec -it -w '$selected' ${CONTAINER_NAME} bash -lc 'exec claude'"
