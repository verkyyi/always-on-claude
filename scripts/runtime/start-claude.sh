#!/bin/bash
# start-claude.sh — Auto-starts the dev container if needed,
# then presents a workspace picker and launches the preferred
# coding assistant inside a named tmux session.
#
# Called automatically from ssh-login.sh on SSH login.

set -euo pipefail

COMPOSE_DIR="${DEV_ENV:-$HOME/dev-env}"

# Load config if available
if [[ -f "$COMPOSE_DIR/scripts/deploy/load-config.sh" ]]; then
    # shellcheck disable=SC1091
    source "$COMPOSE_DIR/scripts/deploy/load-config.sh"
fi

COMPOSE_DIR="${DEV_ENV:-$COMPOSE_DIR}"
: "${CONTAINER_NAME:=claude-dev}"
: "${PROJECTS_DIR:=$HOME/projects}"

MANAGER_PROMPT="$COMPOSE_DIR/scripts/runtime/manager-prompt.txt"
CONTAINER_PROJECTS="/home/dev/projects"
RUNNER_HOST="$COMPOSE_DIR/scripts/runtime/run-code-agent.sh"
RUNNER_CONTAINER="/home/dev/dev-env/scripts/runtime/run-code-agent.sh"

COMPOSE_CMD=(sudo --preserve-env=HOME docker compose)

normalize_code_agent() {
    case "${1:-}" in
        codex) echo "codex" ;;
        claude|"") echo "claude" ;;
        *) echo "claude" ;;
    esac
}

CODE_AGENT=$(normalize_code_agent "${DEFAULT_CODE_AGENT:-claude}")

all_code_agent_session_pattern() {
    echo '^(claude|codex)-'
}

file_sha256() {
    local path="$1"
    [[ -f "$path" ]] || return 0

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    else
        shasum -a 256 "$path" | awk '{print $1}'
    fi
}

container_file_sha256() {
    local path="$1"
    docker exec "$CONTAINER_NAME" bash -lc "
        if [[ -f \"$path\" ]]; then
            if command -v sha256sum >/dev/null 2>&1; then
                sha256sum \"$path\" | awk '{print \\\$1}'
            else
                shasum -a 256 \"$path\" | awk '{print \\\$1}'
            fi
        fi
    " 2>/dev/null || true
}

refresh_container_after_recreate() {
    sleep 2
    "${COMPOSE_CMD[@]}" exec -u root dev bash -c \
        "chown -R dev:dev /home/dev/projects /home/dev/.claude /home/dev/.codex" 2>/dev/null || true
}

ensure_claude_state_mount_current() {
    local host_state="$HOME/.claude.json"
    local container_state="/home/dev/.claude.json"
    local host_sum container_sum

    [[ "${CODE_AGENT:-${DEFAULT_CODE_AGENT:-claude}}" == "claude" ]] || return 0
    [[ -f "$host_state" ]] || return 0
    docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$" || return 0

    host_sum=$(file_sha256 "$host_state")
    container_sum=$(container_file_sha256 "$container_state")

    if [[ -z "$host_sum" || -z "$container_sum" || "$host_sum" == "$container_sum" ]]; then
        return 0
    fi

    if [[ "$(count_sessions)" -gt 0 ]]; then
        echo ""
        echo "  Claude state on the host changed after the container was created."
        echo "  Exit active coding sessions, then retry so the container can be recreated."
        echo ""
        return 1
    fi

    echo "  Refreshing container to sync Claude state..."
    if ! (cd "$COMPOSE_DIR" && "${COMPOSE_CMD[@]}" up -d --force-recreate >/dev/null 2>&1); then
        echo "  Failed to recreate container."
        return 1
    fi

    refresh_container_after_recreate

    container_sum=$(container_file_sha256 "$container_state")
    if [[ -n "$host_sum" && -n "$container_sum" && "$host_sum" != "$container_sum" ]]; then
        echo "  Container Claude state is still stale after recreate."
        return 1
    fi

    return 0
}

next_code_agent() {
    local agent
    agent=$(normalize_code_agent "${1:-${CODE_AGENT:-${DEFAULT_CODE_AGENT:-claude}}}")
    if [[ "$agent" == "codex" ]]; then
        echo "claude"
    else
        echo "codex"
    fi
}

persist_default_code_agent() {
    local agent profile tmp
    agent=$(normalize_code_agent "${1:-claude}")
    profile="$HOME/.bash_profile"

    touch "$profile"

    tmp=$(mktemp)
    awk -v agent="$agent" '
        BEGIN {
            updated = 0
            comment = "# Default coding assistant for the workspace picker"
            export_line = "export DEFAULT_CODE_AGENT=\"" agent "\""
        }
        /^export DEFAULT_CODE_AGENT=/ {
            if (!updated) {
                print export_line
                updated = 1
            }
            next
        }
        { print }
        END {
            if (!updated) {
                if (NR > 0) {
                    print ""
                }
                print comment
                print export_line
            }
        }
    ' "$profile" > "$tmp"
    cat "$tmp" > "$profile"
    rm -f "$tmp"

    DEFAULT_CODE_AGENT="$agent"
    CODE_AGENT="$agent"
    export DEFAULT_CODE_AGENT CODE_AGENT
}

toggle_code_agent() {
    local next_agent
    next_agent=$(next_code_agent "${CODE_AGENT:-${DEFAULT_CODE_AGENT:-claude}}")
    persist_default_code_agent "$next_agent"
    echo ""
    echo "  Default agent set to: $CODE_AGENT"
    echo ""
}

code_agent_session_name() {
    local path="$1"
    local agent
    agent=$(normalize_code_agent "${CODE_AGENT:-${DEFAULT_CODE_AGENT:-claude}}")
    echo "${agent}-$(basename "$path" | tr './:' '-')"
}

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
        | grep -Ec "$(all_code_agent_session_pattern)" || true
}

get_max_sessions() {
    # Env var override
    if [[ -n "${MAX_SESSIONS:-}" ]]; then
        echo "$MAX_SESSIONS"
        return
    fi

    # Auto-calculate: min(memory_based, cpu_count), minimum 1
    # Reserve 512MB for OS (Docker + SSH + earlyoom), ~650MB per coding session
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
        echo "  Each coding session uses ~650 MB — more sessions risk OOM."
        echo ""
        echo "  Options:"
        echo "    - Re-attach to an existing session (select it from the menu)"
        echo "    - Exit a running session ($(tmux_detach_hint) to detach, then /exit inside it)"
        echo ""
        return 1
    fi
    return 0
}

# --- Background container check ---
container_pid=""

ensure_container_bg() {
    (
        if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            exit 0
        else
            cd "$COMPOSE_DIR" && "${COMPOSE_CMD[@]}" up -d >/dev/null 2>&1
            sleep 2
            "${COMPOSE_CMD[@]}" exec -u root dev bash -c \
                "chown -R dev:dev /home/dev/projects /home/dev/.claude /home/dev/.codex" 2>/dev/null || true
        fi
    ) &
    container_pid=$!
}

wait_for_container() {
    if [[ -n "$container_pid" ]]; then
        wait "$container_pid" 2>/dev/null || true
        container_pid=""  # Always clear — prevents cascading failures
    fi

    # Verify container is actually running (handles races and bg failures)
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        return 0
    fi

    # Container not running — try to start it synchronously
    echo "  Starting container..."
    if cd "$COMPOSE_DIR" && "${COMPOSE_CMD[@]}" up -d 2>&1 | tail -1; then
        refresh_container_after_recreate
        return 0
    fi

    echo "  Container failed to start."
    return 1
}

# --- Translate host path to container path ---
to_container_path() {
    echo "${1/$HOME\/projects/$CONTAINER_PROJECTS}"
}

normalize_discovered_path() {
    local path="$1"
    if [[ "$path" == /private/* && -e "${path#/private}" ]]; then
        echo "${path#/private}"
    else
        echo "$path"
    fi
}

# --- Inline discovery (flat: repos + worktrees in one pass) ---
discover_entries() {
    entries=()
    local repo_dirs=()
    if command -v mapfile >/dev/null 2>&1; then
        mapfile -t repo_dirs < <(find "$PROJECTS_DIR" -maxdepth 3 -name ".git" -type d 2>/dev/null | sort)
    else
        local repo_dir
        while IFS= read -r repo_dir; do
            [[ -n "$repo_dir" ]] && repo_dirs+=("$repo_dir")
        done < <(find "$PROJECTS_DIR" -maxdepth 3 -name ".git" -type d 2>/dev/null | sort)
    fi

    [[ ${#repo_dirs[@]} -eq 0 ]] && return

    # Parallel git queries: branch + worktree discovery in one pass per repo
    local tmpdir
    tmpdir=$(mktemp -d)
    for i in "${!repo_dirs[@]}"; do
        local dir
        dir=$(normalize_discovered_path "$(dirname "${repo_dirs[$i]}")")
        (
            branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "unknown")
            echo "$branch" > "$tmpdir/${i}.branch"
            git -C "$dir" worktree list --porcelain 2>/dev/null > "$tmpdir/${i}.worktrees" || true
        ) &
    done
    wait

    for i in "${!repo_dirs[@]}"; do
        local dir
        dir=$(normalize_discovered_path "$(dirname "${repo_dirs[$i]}")")
        local branch
        branch=$(cat "$tmpdir/${i}.branch")
        local repo_name
        repo_name=$(basename "$dir")

        # Add main repo entry: repo_name|branch|path|session_state|session_activity
        entries+=("${repo_name}|${branch}|${dir}|none|0")

        # Parse worktrees from parallel results
        local wt_path="" wt_branch=""
        while IFS= read -r line; do
            if [[ "$line" == "worktree "* ]]; then
                wt_path=$(normalize_discovered_path "${line#worktree }")
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
        done < <(cat "$tmpdir/${i}.worktrees"; echo)
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

        # Only track coding assistant sessions
        [[ "$name" =~ ^(claude|codex)- ]] || continue

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
            local expected_session
            expected_session=$(code_agent_session_name "$path")

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
    local next_agent
    next_agent=$(next_code_agent "${CODE_AGENT:-${DEFAULT_CODE_AGENT:-claude}}")

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
        echo "  Enter=m  agent=${CODE_AGENT}  t=toggle->${next_agent}  m=manage  h=host  c=container"
    else
        local default_display=$(( default_idx + 1 ))
        echo "  Enter=${default_display}  agent=${CODE_AGENT}  t=toggle->${next_agent}  m=manage  h=host  c=container"
    fi
    echo ""
}

# --- Entry selection (unified: re-attach or new session) ---
select_entry() {
    local idx="$1"

    if [[ $idx -lt ${#entries[@]} ]]; then
        IFS='|' read -r _ _ path state _ <<< "${entries[$idx]}"
        local session_name
        session_name=$(code_agent_session_name "$path")

        if [[ "$state" == "idle" || "$state" == "attached" ]]; then
            echo "  -> $session_name"
            echo ""
            tmux attach-session -t "$session_name"
        else
            wait_for_container || return 1
            launch "$path" || return 1
        fi
    else
        # Orphaned session
        local oi=$(( idx - ${#entries[@]} ))
        IFS='|' read -r sname _ _ <<< "${orphaned_sessions[$oi]}"
        echo "  -> $sname"
        echo ""
        tmux attach-session -t "$sname"
    fi
}

# --- Launch Claude Code in selected workspace (inside container) ---
launch() {
    local selected="$1"
    local container_path
    container_path=$(to_container_path "$selected")

    # Create unique tmux session name
    local session_name
    session_name=$(code_agent_session_name "$selected")

    # Check session limit (allows re-attach, blocks new if at limit)
    if ! check_session_limit "$session_name"; then
        return 1
    fi

    if ! ensure_claude_state_mount_current; then
        return 1
    fi

    echo "  -> $session_name"
    echo ""

    tmux new-session -A -s "$session_name" \
        "docker exec -it -e CLAUDE_MOBILE=\"${CLAUDE_MOBILE:-}\" -e OPENAI_API_KEY=\"${OPENAI_API_KEY:-}\" -e ANTHROPIC_API_KEY=\"${ANTHROPIC_API_KEY:-}\" -e DEFAULT_CODE_AGENT=\"$CODE_AGENT\" -w '$container_path' ${CONTAINER_NAME} bash -lc 'exec bash \"$RUNNER_CONTAINER\" --agent \"$CODE_AGENT\"'"
}

# --- Launch Claude on the host (for workspace management / updates) ---
launch_host() {
    local dir="$1"
    local session_name="claude-manager"

    # Check session limit (allows re-attach, blocks new if at limit)
    if ! check_session_limit "$session_name"; then
        return 1
    fi

    echo "  -> $dir (host)"
    echo ""

    tmux new-session -A -s "$session_name" \
        "bash -lc 'exec bash \"$RUNNER_HOST\" --agent claude --cwd \"$dir\" --prompt-file \"$MANAGER_PROMPT\" --message \"Greet me and show what you can help with.\"'"
}

# --- Launch a host shell in tmux ---
launch_shell_host() {
    echo "  -> host shell"
    echo ""
    tmux new-session -A -s "shell-host" "bash -l"
}

# --- Launch a container shell in tmux ---
launch_shell_container() {
    echo "  -> container shell"
    echo ""
    tmux new-session -A -s "shell-container" \
        "docker exec -it ${CONTAINER_NAME} bash -l"
}

# --- Main ---
ensure_container_bg

while true; do
    # Refresh repos and session state each iteration
    discover_entries
    get_sessions
    match_sessions
    compute_default
    show_menu

    read -r -p "  > " choice || true

    if [[ "$choice" == "m" ]]; then
        wait_for_container || continue
        launch_host "$COMPOSE_DIR" || true
        continue
    elif [[ "$choice" == "t" ]]; then
        toggle_code_agent
        continue
    elif [[ "$choice" == "h" ]]; then
        launch_shell_host
        continue
    elif [[ "$choice" == "c" ]]; then
        wait_for_container || continue
        launch_shell_container
        continue
    elif [[ -z "$choice" ]]; then
        # Smart default
        if [[ ${#entries[@]} -eq 0 ]]; then
            wait_for_container || continue
            launch_host "$COMPOSE_DIR" || true
            continue
        else
            select_entry "$default_idx" || continue
        fi
    elif [[ "$choice" =~ ^[0-9]+$ ]]; then
        idx=$(( choice - 1 ))
        total=$(( ${#entries[@]} + ${#orphaned_sessions[@]} ))
        if [[ $idx -ge 0 && $idx -lt $total ]]; then
            select_entry "$idx" || continue
        fi
    fi
done
