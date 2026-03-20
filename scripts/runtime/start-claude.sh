#!/bin/bash
# start-claude.sh — Auto-starts the dev container if needed,
# then presents a two-layer workspace picker and launches Claude Code
# inside a named tmux session.
#
# Layer 1: Pick a repo (or manage workspaces)
# Layer 2: Pick a branch/worktree within that repo (skipped if no worktrees)
#
# Called automatically from ssh-login.sh on SSH login.

set -euo pipefail

COMPOSE_DIR="$HOME/dev-env"
CONTAINER_NAME="claude-dev"
WORKTREE_HELPER="$COMPOSE_DIR/scripts/runtime/worktree-helper.sh"
MANAGER_PROMPT="$COMPOSE_DIR/scripts/runtime/manager-prompt.txt"
CONTAINER_PROJECTS="/home/dev/projects"

# Detect workspace type for correct compose command
WORKSPACE_TYPE="ec2"
if [[ -f "$COMPOSE_DIR/.env.workspace" ]]; then
    WORKSPACE_TYPE=$(grep -oP 'WORKSPACE_TYPE=\K.*' "$COMPOSE_DIR/.env.workspace" 2>/dev/null || echo "ec2")
fi

compose_up() {
    if [[ "$WORKSPACE_TYPE" == "local-mac" ]]; then
        (cd "$COMPOSE_DIR" && docker compose -f docker-compose.yml -f docker-compose.mac.yml up -d)
    else
        (cd "$COMPOSE_DIR" && sudo --preserve-env=HOME docker compose up -d)
    fi
}

# Start container if not running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container not running. Starting..."
    compose_up
    sleep 2
    docker compose exec -u root dev bash -c \
        "chown dev:dev /home/dev/projects /home/dev/.claude" 2>/dev/null || true
fi

# --- Discover repos and worktrees ---
discover() {
    entries=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && entries+=("$line")
    done < <(bash "$WORKTREE_HELPER" list-repos 2>/dev/null | sort)

    repos=()
    repo_paths=()
    for entry in "${entries[@]}"; do
        IFS='|' read -r kind path branch <<< "$entry"
        if [[ "$kind" == "REPO" ]]; then
            repos+=("$path|$branch")
            repo_paths+=("$path")
        fi
    done
}

# --- Get worktrees for a specific repo ---
get_worktrees() {
    local repo_path="$1"
    worktrees=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && worktrees+=("$line")
    done < <(bash "$WORKTREE_HELPER" list-worktrees "$repo_path" 2>/dev/null)
}

# --- Translate host path to container path ---
to_container_path() {
    echo "${1/$HOME\/projects/$CONTAINER_PROJECTS}"
}

# --- Layer 1: Pick a repo ---
show_repos() {
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

    echo ""
    echo "  === Repositories ==="
    local i=1
    for item in "${repos[@]+"${repos[@]}"}"; do
        IFS='|' read -r path branch <<< "$item"
        local short_path="${path#$HOME/}"
        echo "  [$i] ${short_path} (${branch})"
        ((i++))
    done

    if [[ ${#repos[@]} -eq 0 ]]; then
        echo "  (no repos found — press [m] to clone your first repo)"
    fi

    echo "  [m] Manage workspaces"
    echo "      Clone repos, create worktrees, and more"
    echo ""
}

# --- Layer 2: Pick a branch/worktree within a repo ---
show_branches() {
    local repo_path="$1" repo_branch="$2"
    local short_path="${repo_path#$HOME/}"

    echo ""
    echo "  === ${short_path} ==="
    echo "  [1] ${repo_branch} (repo)"

    local i=2
    for wt in "${worktrees[@]+"${worktrees[@]}"}"; do
        IFS='|' read -r _wt_path wt_branch <<< "$wt"
        echo "  [$i] ${wt_branch} (worktree)"
        ((i++))
    done

    echo "  [b] ← Back"
    echo ""
}

# --- Launch Claude Code in selected workspace (inside container) ---
launch() {
    local selected="$1"
    local container_path
    container_path=$(to_container_path "$selected")

    echo "  -> $selected"
    echo ""

    # Create unique tmux session name
    session_name="claude-$(basename "$selected" | tr './:' '-')"

    exec tmux new-session -A -s "$session_name" \
        "docker exec -it -w '$container_path' ${CONTAINER_NAME} bash -lc 'exec claude'"
}

# --- Launch Claude Code on the host (for workspace management / updates) ---
launch_host() {
    local dir="$1"

    echo "  -> $dir (host)"
    echo ""

    exec tmux new-session -A -s "claude-manager" \
        "bash -lc 'cd \"$dir\" && exec claude --append-system-prompt-file \"$MANAGER_PROMPT\" \"Greet me and show what you can help with.\"'"
}

# --- Main ---
discover

selected_path=""
selected_branch=""

# Layer 1 loop
while true; do
    show_repos

    read -rp "  > " choice || true
    echo ""

    if [[ "$choice" == "m" ]]; then
        # Launch Claude on the host for workspace management and updates
        launch_host "$COMPOSE_DIR"
    elif [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#repos[@]}" ]]; then
        IFS='|' read -r selected_path selected_branch <<< "${repos[$((choice - 1))]}"
    elif [[ -z "$choice" || "$choice" == $'\n' ]]; then
        # Default: first repo, or home if none
        if [[ ${#repos[@]} -gt 0 ]]; then
            IFS='|' read -r selected_path selected_branch <<< "${repos[0]}"
        else
            launch "$HOME/projects"
        fi
    else
        continue
    fi

    # Check for worktrees
    get_worktrees "$selected_path"

    # If no worktrees, skip Layer 2 and launch directly
    if [[ ${#worktrees[@]} -eq 0 ]]; then
        launch "$selected_path"
    fi

    # Layer 2 loop
    while true; do
        show_branches "$selected_path" "$selected_branch"

        read -rp "  > " choice2 || true
        echo ""

        if [[ "$choice2" == "b" ]]; then
            break  # Back to Layer 1
        elif [[ "$choice2" == "1" || -z "$choice2" || "$choice2" == $'\n' ]]; then
            # Main repo
            launch "$selected_path"
        elif [[ "$choice2" =~ ^[0-9]+$ && "$choice2" -ge 2 && "$choice2" -le $(( ${#worktrees[@]} + 1 )) ]]; then
            IFS='|' read -r wt_selected _ <<< "${worktrees[$((choice2 - 2))]}"
            launch "$wt_selected"
        fi
    done
done
