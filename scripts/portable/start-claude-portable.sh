#!/bin/bash
# start-claude-portable.sh — Workspace picker for portable (single-container) mode.
#
# Unlike the host-mode start-claude.sh, this runs INSIDE the container.
# No docker exec — launches the preferred coding assistant directly in tmux.
#
# Presents a compact flat menu with repos, worktrees, active sessions, and a
# smart default.
#
# Called automatically from ssh-login-portable.sh on login.

set -euo pipefail

CONFIG_ROOT="${DEV_ENV:-$HOME/dev-env}"

if [[ -f "$CONFIG_ROOT/scripts/deploy/load-config.sh" ]]; then
    # shellcheck disable=SC1091
    source "$CONFIG_ROOT/scripts/deploy/load-config.sh"
fi

DEV_ENV="${DEV_ENV:-$CONFIG_ROOT}"
: "${PROJECTS_DIR:=$HOME/projects}"
MANAGER_PROMPT="$DEV_ENV/scripts/runtime/manager-prompt.txt"
RUNNER="$DEV_ENV/scripts/runtime/run-code-agent.sh"

normalize_code_agent() {
    case "${1:-}" in
        codex) echo "codex" ;;
        claude|"") echo "claude" ;;
        *) echo "claude" ;;
    esac
}

CODE_AGENT=$(normalize_code_agent "${DEFAULT_CODE_AGENT:-claude}")

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

all_code_agent_session_pattern() {
    echo '^(claude|codex)-'
}

all_menu_session_pattern() {
    echo '^((claude|codex)-|shell-)'
}

code_agent_session_name() {
    local path="$1"
    local agent
    agent=$(normalize_code_agent "${CODE_AGENT:-${DEFAULT_CODE_AGENT:-claude}}")
    echo "${agent}-$(basename "$path" | tr './:' '-')"
}

cgroup_memory_limit_mb() {
    local path limit
    for path in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        [[ -r "$path" ]] || continue
        limit=$(cat "$path" 2>/dev/null || true)
        [[ "$limit" =~ ^[0-9]+$ ]] || continue
        # Treat huge cgroup v1 sentinel values as unlimited.
        [[ "$limit" -gt 0 && "$limit" -lt 9000000000000000000 ]] || continue
        echo $((limit / 1024 / 1024))
        return 0
    done
    return 1
}

total_memory_mb() {
    if cgroup_memory_limit_mb; then
        return
    fi

    if [[ -f /proc/meminfo ]]; then
        awk '/MemTotal/ {printf "%.0f\n", $2/1024}' /proc/meminfo
    elif command -v sysctl &>/dev/null; then
        sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f\n", $1/1024/1024}'
    else
        echo 4096
    fi
}

count_sessions() {
    tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep -Ec "$(all_code_agent_session_pattern)" || true
}

get_max_sessions() {
    if [[ -n "${MAX_SESSIONS:-}" ]]; then
        echo "$MAX_SESSIONS"
        return
    fi

    local total_mem_mb cpus mem_based max
    total_mem_mb=$(total_memory_mb)
    cpus=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
    mem_based=$(( (total_mem_mb - 512) / 650 ))
    [[ $mem_based -lt 1 ]] && mem_based=1

    max=$(( mem_based < cpus ? mem_based : cpus ))
    [[ $max -lt 1 ]] && max=1
    echo "$max"
}

tmux_detach_hint() {
    local prefix pretty
    prefix=$(tmux show-option -gv prefix 2>/dev/null || echo "C-b")
    pretty=$(echo "$prefix" | sed 's/C-/Ctrl-/')
    echo "${pretty} d"
}

check_session_limit() {
    local session_name="$1"
    if tmux has-session -t "$session_name" 2>/dev/null; then
        return 0
    fi

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

claude_authenticated() {
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && return 0
    [[ -d "$HOME/.claude" ]] \
        && ls "$HOME/.claude/"*.json &>/dev/null 2>&1 \
        && grep -qr --exclude-dir=debug "oauth" "$HOME/.claude/" 2>/dev/null
}

codex_authenticated() {
    [[ -n "${OPENAI_API_KEY:-}" ]] && return 0
    command -v codex &>/dev/null && codex login status &>/dev/null
}

# --- First-run check: prompt for auth if not configured --------------------

first_run_check() {
    local needs_setup=0

    if ! git config --global user.name &>/dev/null; then
        needs_setup=1
    fi

    if ! gh auth status &>/dev/null 2>&1; then
        needs_setup=1
    fi

    if [[ "$CODE_AGENT" == "codex" ]]; then
        codex_authenticated || needs_setup=1
    else
        claude_authenticated || needs_setup=1
    fi

    if [[ $needs_setup -eq 1 ]]; then
        echo ""
        echo "  First run detected — some auth is not configured."
        echo ""
        echo "  [1] Run setup (git + GitHub CLI + preferred code agent)"
        echo "  [2] Skip for now"
        echo ""
        read -rn 1 -p "  > " setup_choice || true
        echo ""

        if [[ "$setup_choice" == "1" ]]; then
            if [[ -x "$DEV_ENV/scripts/deploy/setup-auth.sh" ]]; then
                bash "$DEV_ENV/scripts/deploy/setup-auth.sh"
            else
                echo "  setup-auth.sh not found — configure manually:"
                echo "    git config --global user.name 'Your Name'"
                echo "    git config --global user.email 'you@example.com'"
                echo "    gh auth login"
                if [[ "$CODE_AGENT" == "codex" ]]; then
                    echo "    codex --login    # choose Sign in with ChatGPT for subscription access"
                else
                    echo "    claude login"
                fi
            fi
        fi
    fi
}

# --- Repo and worktree discovery -------------------------------------------

normalize_discovered_path() {
    local path="$1"
    if [[ "$path" == /private/* && -e "${path#/private}" ]]; then
        echo "${path#/private}"
    else
        echo "$path"
    fi
}

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
        local branch repo_name
        branch=$(cat "$tmpdir/${i}.branch")
        repo_name=$(basename "$dir")

        entries+=("${repo_name}|${branch}|${dir}|none|0")

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

# --- Session matching --------------------------------------------------------

get_sessions() {
    session_names=()
    session_states=()
    session_activities=()

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name attached activity
        read -r name attached activity <<< "$line"

        [[ "$name" =~ $(all_menu_session_pattern) ]] || continue

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

compute_default() {
    default_idx=0

    [[ ${#entries[@]} -eq 0 ]] && return

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

# --- Compact menu rendering --------------------------------------------------

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

            if [[ "$repo_name" != "$prev_repo" ]]; then
                [[ -n "$prev_repo" ]] && echo ""
                echo "  ${repo_name}"
                prev_repo="$repo_name"
            fi

            local marker=""
            if [[ "$state" == "idle" ]]; then
                marker="  <- active (idle)"
            elif [[ "$state" == "attached" ]]; then
                marker="  <- active (attached)"
            fi

            echo "  [${idx}] ${branch}${marker}"
            ((idx++))
        done
    fi

    if [[ ${#orphaned_sessions[@]} -gt 0 ]]; then
        echo ""
        echo "  sessions"
        for os in "${orphaned_sessions[@]}"; do
            IFS='|' read -r sname sstate _ <<< "$os"
            local omarker=""
            [[ "$sstate" == "attached" ]] && omarker="  <- active (attached)"
            [[ "$sstate" == "idle" ]] && omarker="  <- active (idle)"
            echo "  [${idx}] ${sname}${omarker}"
            ((idx++))
        done
    fi

    echo ""
    if [[ ${#entries[@]} -eq 0 ]]; then
        echo "  Enter=m  agent=${CODE_AGENT}  t=toggle->${next_agent}  m=manage  h=shell"
    else
        local default_display=$(( default_idx + 1 ))
        echo "  Enter=${default_display}  agent=${CODE_AGENT}  t=toggle->${next_agent}  m=manage  h=shell"
    fi
    echo ""
}

# --- Entry selection: reattach or launch -------------------------------------

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
            launch "$path" || return 1
        fi
    else
        local oi=$(( idx - ${#entries[@]} ))
        IFS='|' read -r sname _ _ <<< "${orphaned_sessions[$oi]}"
        echo "  -> $sname"
        echo ""
        tmux attach-session -t "$sname"
    fi
}

# --- Launch the preferred code agent directly in tmux ------------------------

launch() {
    local selected="$1"
    local session_name
    session_name=$(code_agent_session_name "$selected")

    if ! check_session_limit "$session_name"; then
        return 1
    fi

    echo "  -> $session_name"
    echo ""

    tmux new-session -A -s "$session_name" \
        "bash -lc 'exec bash \"$RUNNER\" --agent \"$CODE_AGENT\" --cwd \"$selected\"'"
}

# --- Launch Claude for workspace management ----------------------------------

launch_manager() {
    local dir="$1"
    local session_name="claude-manager"

    if ! check_session_limit "$session_name"; then
        return 1
    fi

    echo "  -> workspace manager"
    echo ""

    tmux new-session -A -s "$session_name" \
        "bash -lc 'exec bash \"$RUNNER\" --agent claude --cwd \"$dir\" --prompt-file \"$MANAGER_PROMPT\" --message \"Greet me and show what you can help with.\"'"
}

# --- Launch a shell in tmux ---------------------------------------------------

launch_shell() {
    echo "  -> shell"
    echo ""
    tmux new-session -A -s "shell-local" "bash -l"
}

# --- Main ---------------------------------------------------------------------

first_run_check

while true; do
    discover_entries
    get_sessions
    match_sessions
    compute_default
    show_menu

    read -r -p "  > " choice || true

    if [[ "$choice" == "m" ]]; then
        launch_manager "$DEV_ENV" || true
        continue
    elif [[ "$choice" == "t" ]]; then
        toggle_code_agent
        continue
    elif [[ "$choice" == "h" ]]; then
        launch_shell
        continue
    elif [[ -z "$choice" ]]; then
        if [[ ${#entries[@]} -eq 0 ]]; then
            launch_manager "$DEV_ENV" || true
        else
            select_entry "$default_idx" || true
        fi
        continue
    elif [[ "$choice" =~ ^[0-9]+$ ]]; then
        idx=$(( choice - 1 ))
        total=$(( ${#entries[@]} + ${#orphaned_sessions[@]} ))
        if [[ $idx -ge 0 && $idx -lt $total ]]; then
            select_entry "$idx" || true
        fi
    fi
done
