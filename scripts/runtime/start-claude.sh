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

COMPOSE_DIR="${DEV_ENV:-$HOME/dev-env}"

# Load config if available
if [[ -f "$COMPOSE_DIR/scripts/deploy/load-config.sh" ]]; then
    # shellcheck disable=SC1091
    source "$COMPOSE_DIR/scripts/deploy/load-config.sh"
fi

: "${CONTAINER_NAME:=claude-dev}"
: "${PROJECTS_DIR:=$HOME/projects}"

WORKTREE_HELPER="$COMPOSE_DIR/scripts/runtime/worktree-helper.sh"
MANAGER_PROMPT="$COMPOSE_DIR/scripts/runtime/manager-prompt.txt"
CONTAINER_PROJECTS="/home/dev/projects"

COMPOSE_CMD=(sudo --preserve-env=HOME docker compose)

# --- tmux prefix detection ---
tmux_detach_hint() {
    local prefix
    prefix=$(tmux show-option -gv prefix 2>/dev/null || echo "C-b")
    local pretty
    pretty=$(echo "$prefix" | sed 's/C-/Ctrl-/')
    echo "${pretty} d"
}

# --- Session limit helpers ---
count_sessions() {
    tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep -c '^claude-' || echo 0
}

get_max_sessions() {
    # Env var override
    if [[ -n "${MAX_SESSIONS:-}" ]]; then
        echo "$MAX_SESSIONS"
        return
    fi

    # Auto-calculate: min(memory_based, cpu_count), minimum 1
    # Reserve 512MB for OS (Docker + SSH + earlyoom), ~650MB per Claude session
    local total_mem_mb cpus mem_based max
    if [[ -f /proc/meminfo ]]; then
        total_mem_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    elif command -v sysctl &>/dev/null; then
        total_mem_mb=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}')
    else
        total_mem_mb=4096
    fi

    cpus=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
    mem_based=$(( (total_mem_mb - 512) / 650 ))
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
        echo "    - Exit a running session ($(tmux_detach_hint) to detach, then /exit inside it)"
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
    "${COMPOSE_CMD[@]}" exec -u root dev bash -c \
        "chown -R dev:dev /home/dev/projects" 2>/dev/null || true
fi

# --- Discover repos and worktrees ---
discover() {
    entries=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && entries+=("$line")
    done < <(bash "$WORKTREE_HELPER" list-repos 2>/dev/null | sort)

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
    echo "${1/$HOME\/projects/$CONTAINER_PROJECTS}"
}

# --- Inline discovery (flat: repos + worktrees in one pass) ---
discover_entries() {
    entries=()
    local repo_dirs=()
    mapfile -t repo_dirs < <(find "$PROJECTS_DIR" -maxdepth 3 -name ".git" -type d 2>/dev/null | sort)

    [[ ${#repo_dirs[@]} -eq 0 ]] && return

    # Parallel git branch queries
    local tmpdir
    tmpdir=$(mktemp -d)
    for i in "${!repo_dirs[@]}"; do
        local dir
        dir=$(dirname "${repo_dirs[$i]}")
        ( git -C "$dir" branch --show-current 2>/dev/null || echo "unknown" ) > "$tmpdir/$i" &
    done
    wait

    for i in "${!repo_dirs[@]}"; do
        local dir
        dir=$(dirname "${repo_dirs[$i]}")
        local branch
        branch=$(cat "$tmpdir/$i")
        local repo_name
        repo_name=$(basename "$dir")

        # Add main repo entry: repo_name|branch|path|session_state|session_activity
        entries+=("${repo_name}|${branch}|${dir}|none|0")

        # Discover worktrees for this repo
        local wt_path="" wt_branch=""
        while IFS= read -r line; do
            if [[ "$line" == "worktree "* ]]; then
                wt_path="${line#worktree }"
                wt_branch=""
            elif [[ "$line" == "branch "* ]]; then
                wt_branch="${line#branch refs/heads/}"
            elif [[ -z "$line" ]]; then
                if [[ "$wt_path" != "$dir" && -n "$wt_branch" ]]; then
                    entries+=("${repo_name}|${wt_branch}|${wt_path}|none|0")
                fi
                wt_path=""
                wt_branch=""
            fi
        done < <(git -C "$dir" worktree list --porcelain 2>/dev/null; echo)
    done

    rm -rf "$tmpdir"
}

# --- Session matching ---
get_sessions() {
    session_names=()
    session_states=()
    session_activities=()

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name attached activity
        read -r name attached activity <<< "$line"

        # Only track claude-* sessions
        [[ "$name" == claude-* ]] || continue

        session_names+=("$name")
        if [[ "$attached" -gt 0 ]]; then
            session_states+=("attached")
        else
            session_states+=("idle")
        fi
        session_activities+=("$activity")
    done < <(tmux list-sessions -F '#{session_name} #{session_attached} #{session_activity}' 2>/dev/null || true)
}

match_sessions() {
    orphaned_sessions=()

    for si in "${!session_names[@]}"; do
        local sname="${session_names[$si]}"
        local sstate="${session_states[$si]}"
        local sactivity="${session_activities[$si]}"
        local found=false

        for ei in "${!entries[@]}"; do
            IFS='|' read -r repo_name branch path _state _activity <<< "${entries[$ei]}"
            local dir_base
            dir_base=$(basename "$path" | tr './:' '-')
            local expected_session="claude-${dir_base}"

            if [[ "$sname" == "$expected_session" ]]; then
                entries[$ei]="${repo_name}|${branch}|${path}|${sstate}|${sactivity}"
                found=true
                break
            fi
        done

        if [[ "$found" == false ]]; then
            orphaned_sessions+=("${sname}|${sstate}|${sactivity}")
        fi
    done
}

# --- Smart default ---
compute_default() {
    default_idx=0

    [[ ${#entries[@]} -eq 0 ]] && return

    # Find the most recently active idle session
    local best_idx=-1
    local best_activity=0

    for i in "${!entries[@]}"; do
        IFS='|' read -r _ _ _ state activity <<< "${entries[$i]}"
        if [[ "$state" == "idle" && "$activity" -gt "$best_activity" ]]; then
            best_activity="$activity"
            best_idx=$i
        fi
    done

    if [[ $best_idx -ge 0 ]]; then
        default_idx=$best_idx
    fi
}

# --- Compact menu rendering ---
show_menu() {
    local prev_repo=""
    local idx=1

    echo ""

    if [[ ${#entries[@]} -eq 0 ]]; then
        echo "  (no repos — press m to clone)"
    else
        for i in "${!entries[@]}"; do
            IFS='|' read -r repo_name branch path state activity <<< "${entries[$i]}"

            # Print repo header when repo changes
            if [[ "$repo_name" != "$prev_repo" ]]; then
                [[ -n "$prev_repo" ]] && echo ""
                echo "  ${repo_name}"
                prev_repo="$repo_name"
            fi

            # Branch line with optional session marker
            local marker=""
            if [[ "$state" == "idle" ]]; then
                marker="  ← active (idle)"
            elif [[ "$state" == "attached" ]]; then
                marker="  ← active (attached)"
            fi

            echo "  [${idx}] ${branch}${marker}"
            ((idx++))
        done
    fi

    # Orphaned sessions
    if [[ ${#orphaned_sessions[@]} -gt 0 ]]; then
        echo ""
        echo "  sessions"
        for os in "${orphaned_sessions[@]}"; do
            IFS='|' read -r sname sstate _ <<< "$os"
            local omarker=""
            [[ "$sstate" == "attached" ]] && omarker="  ← active (attached)"
            [[ "$sstate" == "idle" ]] && omarker="  ← active (idle)"
            echo "  [${idx}] ${sname}${omarker}"
            ((idx++))
        done
    fi

    # Footer
    echo ""
    if [[ ${#entries[@]} -eq 0 ]]; then
        echo "  Enter=m  m=manage  h=host  c=container"
    else
        local default_display=$(( default_idx + 1 ))
        echo "  Enter=${default_display}  m=manage  h=host  c=container"
    fi
    echo ""
}

# --- Layer 1: Pick a repo ---
show_repos() {
    # Collect active claude-* and shell-* tmux sessions
    # Note: all_sessions is intentionally global — read by reattach_session()
    all_sessions=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && all_sessions+=("$line")
    done < <(tmux list-sessions -F '#{session_name} #{?session_attached,(attached),(idle)}' 2>/dev/null \
        | grep -E '^(claude-|shell-)' || true)

    if [[ ${#all_sessions[@]} -gt 0 ]]; then
        echo ""
        echo "  === Active sessions ($(count_sessions)/$(get_max_sessions)) ==="
        local ai=1
        for s in "${all_sessions[@]}"; do
            echo "  [a${ai}] $s"
            ((ai++))
        done
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
    echo "  [h] Host shell"
    echo "  [c] Container shell"
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

    # Create unique tmux session name
    session_name="claude-$(basename "$selected" | tr './:' '-')"

    # Check session limit (allows re-attach, blocks new if at limit)
    if ! check_session_limit "$session_name"; then
        return 1
    fi

    echo "  -> $selected"
    echo ""

    exec tmux new-session -A -s "$session_name" \
        "docker exec -it -e CLAUDE_MOBILE=\"${CLAUDE_MOBILE:-}\" -w '$container_path' ${CONTAINER_NAME} bash -lc 'exec claude'"
}

# --- Launch Claude Code on the host (for workspace management / updates) ---
launch_host() {
    local dir="$1"

    # Check session limit (allows re-attach, blocks new if at limit)
    if ! check_session_limit "claude-manager"; then
        return 1
    fi

    echo "  -> $dir (host)"
    echo ""

    exec tmux new-session -A -s "claude-manager" \
        "bash -lc 'cd \"$dir\" && exec claude --append-system-prompt-file \"$MANAGER_PROMPT\" \"Greet me and show what you can help with.\"'"
}

# --- Launch a host shell in tmux ---
launch_shell_host() {
    echo "  -> host shell"
    echo ""
    exec tmux new-session -A -s "shell-host" "bash -l"
}

# --- Launch a container shell in tmux ---
launch_shell_container() {
    echo "  -> container shell"
    echo ""
    exec tmux new-session -A -s "shell-container" \
        "docker exec -it ${CONTAINER_NAME} bash -l"
}

# --- Reattach to an active session by index ---
# Note: all_sessions is intentionally global — populated by show_repos(), read here
reattach_session() {
    local idx="$1"
    if [[ $idx -ge 1 && $idx -le ${#all_sessions[@]} ]]; then
        local session_line="${all_sessions[$((idx - 1))]}"
        local session_name="${session_line%% *}"
        echo "  -> reattach $session_name"
        echo ""
        exec tmux attach-session -t "$session_name"
    fi
    return 1
}

# --- Main ---
discover

# Layer 1 loop
while true; do
    show_repos

    read -r -p "  > " choice || true

    if [[ "$choice" == "m" ]]; then
        # Launch Claude on the host for workspace management and updates
        launch_host "$COMPOSE_DIR" || continue
    elif [[ "$choice" == "h" ]]; then
        launch_shell_host
    elif [[ "$choice" == "c" ]]; then
        launch_shell_container
    elif [[ "$choice" =~ ^a([0-9]+)$ ]]; then
        reattach_session "${BASH_REMATCH[1]}" || continue
    elif [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#repos[@]}" ]]; then
        IFS='|' read -r selected_path selected_branch <<< "${repos[$((choice - 1))]}"
    elif [[ -z "$choice" ]]; then
        # Default: first repo, or home if none
        if [[ ${#repos[@]} -gt 0 ]]; then
            IFS='|' read -r selected_path selected_branch <<< "${repos[0]}"
        else
            launch "$HOME/projects" || continue
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

        read -r -p "  > " choice2 || true

        if [[ "$choice2" == "b" ]]; then
            break  # Back to Layer 1
        elif [[ "$choice2" == "1" || -z "$choice2" ]]; then
            # Main repo
            launch "$selected_path" || continue
        elif [[ "$choice2" =~ ^[0-9]+$ && "$choice2" -ge 2 && "$choice2" -le $(( ${#worktrees[@]} + 1 )) ]]; then
            IFS='|' read -r wt_selected _ <<< "${worktrees[$((choice2 - 2))]}"
            launch "$wt_selected" || continue
        fi
    done
done
