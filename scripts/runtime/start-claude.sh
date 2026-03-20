#!/bin/bash
# start-claude.sh — Auto-starts the dev container if needed,
# then presents a two-layer workspace picker and launches Claude Code
# inside a named tmux session.
#
# Layer 1: Pick a repo (or manage workspaces)
# Layer 2: Pick a branch/worktree within that repo (skipped if no worktrees)
#
# Multi-user aware: uses CLAUDE_USER, CLAUDE_CONTAINER, and
# CLAUDE_USER_HOME env vars when set by ssh-login.sh. Falls back
# to single-user defaults.
#
# Called automatically from ssh-login.sh on SSH login.

set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/home/dev/dev-env}"
WORKTREE_HELPER="$COMPOSE_DIR/scripts/runtime/worktree-helper.sh"
MANAGER_PROMPT="$COMPOSE_DIR/scripts/runtime/manager-prompt.txt"
CONTAINER_PROJECTS="/home/dev/projects"

# --- Multi-user detection ---
# CLAUDE_USER is set by ssh-login.sh for multi-user setups
CLAUDE_USER="${CLAUDE_USER:-}"
CONTAINER_NAME="${CLAUDE_CONTAINER:-claude-dev}"
USER_HOME="${CLAUDE_USER_HOME:-$HOME}"

# The host-side projects directory (where repos live on the host filesystem)
HOST_PROJECTS="$USER_HOME/projects"

# Detect workspace type (default to ec2 for backward compatibility)
WORKSPACE_TYPE="ec2"
if [[ -f "$COMPOSE_DIR/.env.workspace" ]]; then
    source "$COMPOSE_DIR/.env.workspace" 2>/dev/null || true
fi

# Build compose command based on workspace type and user
build_compose_cmd() {
    local cmd=(docker compose)

    if [[ -n "$CLAUDE_USER" ]]; then
        # Multi-user: use per-user compose file
        local user_compose="$COMPOSE_DIR/docker-compose.user-${CLAUDE_USER}.yml"
        if [[ -f "$user_compose" ]]; then
            cmd=(docker compose -f "$user_compose")
        fi
    fi

    if [[ "$WORKSPACE_TYPE" == "local-mac" && -z "$CLAUDE_USER" ]]; then
        cmd=(docker compose -f docker-compose.yml -f docker-compose.mac.yml)
    fi

    echo "${cmd[@]}"
}

COMPOSE_CMD_STR=$(build_compose_cmd)
read -ra COMPOSE_CMD <<< "$COMPOSE_CMD_STR"

# Service name inside the compose file
if [[ -n "$CLAUDE_USER" ]]; then
    COMPOSE_SERVICE="dev-${CLAUDE_USER}"
else
    COMPOSE_SERVICE="dev"
fi

# --- Session limit helpers ---
count_sessions() {
    local prefix="claude-"
    if [[ -n "$CLAUDE_USER" ]]; then
        prefix="claude-${CLAUDE_USER}-"
    fi
    tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep -c "^${prefix}" || echo 0
}

get_max_sessions() {
    # Env var override
    if [[ -n "${MAX_SESSIONS:-}" ]]; then
        echo "$MAX_SESSIONS"
        return
    fi

    # Auto-calculate: min(memory_based, cpu_count), minimum 1
    local total_mem_mb cpus mem_based max
    if [[ -f /proc/meminfo ]]; then
        total_mem_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    elif command -v sysctl &>/dev/null; then
        total_mem_mb=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}')
    else
        total_mem_mb=4096
    fi

    cpus=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
    mem_based=$(( (total_mem_mb - 1024) / 650 ))
    [[ $mem_based -lt 1 ]] && mem_based=1

    max=$(( mem_based < cpus ? mem_based : cpus ))
    [[ $max -lt 1 ]] && max=1
    echo "$max"
}

check_session_limit() {
    local session_name="$1"
    # Always allow re-attaching to an existing session
    if tmux has-session -t "$session_name" 2>/dev/null; then
        return 0
    fi
    # Check limit for new sessions
    local current max
    current=$(count_sessions)
    max=$(get_max_sessions)
    if [[ $current -ge $max ]]; then
        echo ""
        echo "  Session limit reached ($current/$max)."
        echo "  Each Claude session uses ~650 MB — more sessions risk OOM."
        echo ""
        echo "  Options:"
        echo "    - Re-attach to an existing session (select it from the menu)"
        echo "    - Exit a running session (Ctrl-b d to detach, then /exit inside it)"
        echo ""
        return 1
    fi
    return 0
}

# Start container if not running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container not running. Starting..."
    cd "$COMPOSE_DIR" && "${COMPOSE_CMD[@]}" up -d
    sleep 2
    "${COMPOSE_CMD[@]}" exec -T -u root "$COMPOSE_SERVICE" bash -c \
        "chown -R dev:dev /home/dev/projects" 2>/dev/null || true
fi

# --- Discover repos and worktrees ---
discover() {
    entries=()
    # Use the host-side projects directory for discovery
    while IFS= read -r line; do
        [[ -n "$line" ]] && entries+=("$line")
    done < <(PROJECTS_DIR="$HOST_PROJECTS" bash "$WORKTREE_HELPER" list-repos 2>/dev/null | sort)

    repos=()
    repo_paths=()
    for entry in ${entries[@]+"${entries[@]}"}; do
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
    echo "${1/$HOST_PROJECTS/$CONTAINER_PROJECTS}"
}

# --- Layer 1: Pick a repo ---
show_repos() {
    # Show user context in multi-user mode
    if [[ -n "$CLAUDE_USER" ]]; then
        echo ""
        echo "  User: $CLAUDE_USER | Container: $CONTAINER_NAME"
    fi

    # Show active claude-* tmux sessions (scoped to this user)
    local sessions session_prefix
    if [[ -n "$CLAUDE_USER" ]]; then
        session_prefix="claude-${CLAUDE_USER}-"
    else
        session_prefix="claude-"
    fi
    sessions=$(tmux list-sessions -F '#{session_name} #{?session_attached,(attached),(idle)}' 2>/dev/null \
        | grep "^${session_prefix}" || true)

    if [[ -n "$sessions" ]]; then
        echo ""
        echo "  === Active sessions ($(count_sessions)/$(get_max_sessions)) ==="
        while IFS= read -r line; do
            echo "  $line"
        done <<< "$sessions"
    fi

    echo ""
    echo "  === Repositories ==="
    local i=1
    for item in "${repos[@]+"${repos[@]}"}"; do
        IFS='|' read -r path branch <<< "$item"
        local short_path="${path#$HOST_PROJECTS/}"
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
    local short_path="${repo_path#$HOST_PROJECTS/}"

    echo ""
    echo "  === ${short_path} ==="
    echo "  [1] ${repo_branch} (repo)"

    local i=2
    for wt in "${worktrees[@]+"${worktrees[@]}"}"; do
        IFS='|' read -r _wt_path wt_branch <<< "$wt"
        echo "  [$i] ${wt_branch} (worktree)"
        ((i++))
    done

    echo "  [b] <- Back"
    echo ""
}

# --- Launch Claude Code in selected workspace (inside container) ---
launch() {
    local selected="$1"
    local container_path
    container_path=$(to_container_path "$selected")

    # Create unique tmux session name (scoped to user in multi-user mode)
    local base_name
    base_name="$(basename "$selected" | tr './:' '-')"
    if [[ -n "$CLAUDE_USER" ]]; then
        session_name="claude-${CLAUDE_USER}-${base_name}"
    else
        session_name="claude-${base_name}"
    fi

    # Check session limit (allows re-attach, blocks new if at limit)
    if ! check_session_limit "$session_name"; then
        return 1
    fi

    echo "  -> $selected"
    echo ""

    exec tmux new-session -A -s "$session_name" \
        "docker exec -it -w '$container_path' ${CONTAINER_NAME} bash -lc 'exec claude'"
}

# --- Launch Claude Code on the host (for workspace management / updates) ---
launch_host() {
    local dir="$1"
    local manager_session="claude-manager"
    if [[ -n "$CLAUDE_USER" ]]; then
        manager_session="claude-${CLAUDE_USER}-manager"
    fi

    # Check session limit (allows re-attach, blocks new if at limit)
    if ! check_session_limit "$manager_session"; then
        return 1
    fi

    echo "  -> $dir (host)"
    echo ""

    exec tmux new-session -A -s "$manager_session" \
        "bash -lc 'cd \"$dir\" && exec claude --append-system-prompt-file \"$MANAGER_PROMPT\" \"Greet me and show what you can help with.\"'"
}

# --- Main ---
discover

# Layer 1 loop
while true; do
    show_repos

    read -n 1 -p "  > " choice || true
    echo ""

    if [[ "$choice" == "m" ]]; then
        # Launch Claude on the host for workspace management and updates
        launch_host "$COMPOSE_DIR" || continue
    elif [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#repos[@]}" ]]; then
        IFS='|' read -r selected_path selected_branch <<< "${repos[$((choice - 1))]}"
    elif [[ -z "$choice" || "$choice" == $'\n' ]]; then
        # Default: first repo, or home if none
        if [[ ${#repos[@]} -gt 0 ]]; then
            IFS='|' read -r selected_path selected_branch <<< "${repos[0]}"
        else
            launch "$HOST_PROJECTS" || continue
        fi
    else
        continue
    fi

    # Check for worktrees
    get_worktrees "$selected_path"

    # If no worktrees, skip Layer 2 and launch directly
    if [[ ${#worktrees[@]} -eq 0 ]]; then
        launch "$selected_path" || continue
    fi

    # Layer 2 loop
    while true; do
        show_branches "$selected_path" "$selected_branch"

        read -n 1 -p "  > " choice2 || true
        echo ""

        if [[ "$choice2" == "b" ]]; then
            break  # Back to Layer 1
        elif [[ "$choice2" == "1" || -z "$choice2" || "$choice2" == $'\n' ]]; then
            # Main repo
            launch "$selected_path" || continue
        elif [[ "$choice2" =~ ^[0-9]+$ && "$choice2" -ge 2 && "$choice2" -le $(( ${#worktrees[@]} + 1 )) ]]; then
            IFS='|' read -r wt_selected _ <<< "${worktrees[$((choice2 - 2))]}"
            launch "$wt_selected" || continue
        fi
    done
done
