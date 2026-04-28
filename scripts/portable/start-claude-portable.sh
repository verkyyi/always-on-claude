#!/bin/bash
# start-claude-portable.sh — Workspace picker for portable (single-container) mode.
#
# Unlike the host-mode start-claude.sh, this runs INSIDE the container.
# No docker exec — launches the preferred coding assistant directly in tmux.
#
# Called automatically from ssh-login-portable.sh on login.

set -euo pipefail

CONFIG_ROOT="${DEV_ENV:-$HOME/dev-env}"
COMMON_LIB="$CONFIG_ROOT/scripts/lib/start-menu-common.sh"

if [[ -f "$CONFIG_ROOT/scripts/deploy/load-config.sh" ]]; then
    # shellcheck disable=SC1091
    source "$CONFIG_ROOT/scripts/deploy/load-config.sh"
fi

DEV_ENV="${DEV_ENV:-$CONFIG_ROOT}"
: "${PROJECTS_DIR:=$HOME/projects}"
MANAGER_PROMPT="$DEV_ENV/scripts/runtime/manager-prompt.txt"
RUNNER="$DEV_ENV/scripts/runtime/run-code-agent.sh"
# Shared picker config consumed by scripts/lib/start-menu-common.sh.
# shellcheck disable=SC2034
MANAGER_TARGET="$DEV_ENV"
# shellcheck disable=SC2034
MENU_ACTIONS="h=shell"
WORKTREE_HELPER="$DEV_ENV/scripts/runtime/worktree-helper.sh"
MENU_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/aoc/start-menu"
MENU_SYNC_TTL="${AOC_MENU_SYNC_TTL:-600}"
MENU_CLEANUP_TTL="${AOC_MENU_CLEANUP_TTL:-300}"

# shellcheck source=../lib/start-menu-common.sh
source "$COMMON_LIB"

CODE_AGENT=$(normalize_code_agent "${DEFAULT_CODE_AGENT:-claude}")

cgroup_memory_limit_mb() {
    local path limit
    for path in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        [[ -r "$path" ]] || continue
        limit=$(cat "$path" 2>/dev/null || true)
        [[ "$limit" =~ ^[0-9]+$ ]] || continue
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

launch() {
    local selected="$1"
    local branch="${2:-}"
    local repo_name="${3:-$(basename "$selected")}"
    local session_name
    session_name=$(code_agent_session_name "$selected")

    if ! check_session_limit "$session_name"; then
        return 1
    fi

    echo "  -> $session_name"
    echo ""

    AOC_SESSION_PATH="$selected" \
    AOC_SESSION_REPO="$repo_name" \
    AOC_SESSION_BRANCH="$branch" \
    new_or_attach_tmux_session "$session_name" \
        "bash -lc 'exec bash \"$RUNNER\" --agent \"$CODE_AGENT\" --cwd \"$selected\" --resume-latest'"
}

launch_manager() {
    local dir="$1"
    local session_name="claude-manager"

    if ! check_session_limit "$session_name"; then
        return 1
    fi

    echo "  -> workspace manager"
    echo ""

    new_or_attach_tmux_session "$session_name" \
        "bash -lc 'exec bash \"$RUNNER\" --agent claude --cwd \"$dir\" --prompt-file \"$MANAGER_PROMPT\" --message \"Greet me and show what you can help with.\"'"
}

launch_shell() {
    echo "  -> shell"
    echo ""
    new_or_attach_tmux_session "shell-local" "bash -l"
}

session_matches_repo_path() {
    local repo_path="$1"
    local session_agent expected_session
    expected_session=$(code_agent_session_name_for_agent "claude" "$repo_path")

    # shellcheck disable=SC2154  # session_names/session_paths set in start-menu-common.sh
    for si in "${!session_names[@]}"; do
        if [[ -n "${session_paths[$si]:-}" && "${session_paths[$si]}" == "$repo_path" ]]; then
            return 0
        fi

        session_agent=$(session_agent_from_name "${session_names[$si]}")
        if [[ -n "$session_agent" ]]; then
            expected_session=$(code_agent_session_name_for_agent "$session_agent" "$repo_path")
            [[ "${session_names[$si]}" == "$expected_session" ]] && return 0
        fi
    done

    return 1
}

active_worktree_keep_args() {
    ACTIVE_WORKTREE_KEEP_ARGS=()
    local seen="" spath
    for spath in "${session_paths[@]:-}"; do
        [[ -n "$spath" ]] || continue
        [[ -d "$spath" ]] || continue
        if [[ "$seen" == *"|$spath|"* ]]; then
            continue
        fi
        ACTIVE_WORKTREE_KEEP_ARGS+=("--keep-path" "$spath")
        seen="${seen}|${spath}|"
    done
}

sync_repo_or_warn() {
    local repo_path="$1"
    if ! bash "$WORKTREE_HELPER" sync-repo "$repo_path" >/dev/null 2>&1; then
        PROJECT_SYNC_WARNINGS+=("${repo_path}|needs cleanup")
        return 1
    fi
    return 0
}

repo_cache_key() {
    echo "$1" | tr '/:' '__'
}

ensure_menu_cache_dirs() {
    mkdir -p "$MENU_CACHE_DIR/warnings" "$MENU_CACHE_DIR/refreshing" "$MENU_CACHE_DIR/stamps"
}

repo_warning_file() {
    echo "$MENU_CACHE_DIR/warnings/$(repo_cache_key "$1")"
}

repo_refreshing_file() {
    echo "$MENU_CACHE_DIR/refreshing/$(repo_cache_key "$1")"
}

repo_stamp_file() {
    echo "$MENU_CACHE_DIR/stamps/$(repo_cache_key "$1")"
}

cleanup_stamp_file() {
    echo "$MENU_CACHE_DIR/cleanup.stamp"
}

now_epoch() {
    date +%s
}

file_age_seconds() {
    local path="$1"
    [[ -e "$path" ]] || return 1
    local modified
    modified=$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || return 1)
    echo $(( $(now_epoch) - modified ))
}

repo_sync_due() {
    local repo_path="$1"
    local stamp
    stamp=$(repo_stamp_file "$repo_path")
    local age
    age=$(file_age_seconds "$stamp" 2>/dev/null || echo $((MENU_SYNC_TTL + 1)))
    [[ "$age" -ge "$MENU_SYNC_TTL" ]]
}

cleanup_due() {
    local age
    age=$(file_age_seconds "$(cleanup_stamp_file)" 2>/dev/null || echo $((MENU_CLEANUP_TTL + 1)))
    [[ "$age" -ge "$MENU_CLEANUP_TTL" ]]
}

mark_repo_warning() {
    local repo_path="$1" message="$2"
    printf '%s\n' "$message" > "$(repo_warning_file "$repo_path")"
}

clear_repo_warning() {
    ensure_menu_cache_dirs
    rm -f "$(repo_warning_file "$1")"
}

mark_repo_refreshed() {
    ensure_menu_cache_dirs
    touch "$(repo_stamp_file "$1")"
}

load_maintenance_state() {
    ensure_menu_cache_dirs
    PROJECT_SYNC_WARNINGS=()
    PROJECT_SYNC_REFRESHING=()

    local repo_dir repo_path warning_file message refreshing_file
    while IFS= read -r repo_dir; do
        [[ -n "$repo_dir" ]] || continue
        repo_path=$(normalize_discovered_path "$(dirname "$repo_dir")")
        warning_file=$(repo_warning_file "$repo_path")
        refreshing_file=$(repo_refreshing_file "$repo_path")
        if [[ -f "$warning_file" ]]; then
            message=$(cat "$warning_file" 2>/dev/null || true)
            [[ -n "$message" ]] && PROJECT_SYNC_WARNINGS+=("${repo_path}|${message}")
        fi
        if [[ -f "$refreshing_file" ]]; then
            PROJECT_SYNC_REFRESHING+=("$repo_path")
        fi
    done < <(project_repo_paths)
}

run_background_maintenance() {
    [[ -x "$WORKTREE_HELPER" ]] || return 0

    ensure_menu_cache_dirs
    active_worktree_keep_args
    local lock_dir="$MENU_CACHE_DIR/maintenance.lock"
    mkdir "$lock_dir" 2>/dev/null || return 0

    local repo_dir repo_path
    (
        trap 'rm -rf "$lock_dir"' EXIT

        if cleanup_due; then
            if [[ ${#ACTIVE_WORKTREE_KEEP_ARGS[@]} -gt 0 ]]; then
                bash "$WORKTREE_HELPER" cleanup --quiet "${ACTIVE_WORKTREE_KEEP_ARGS[@]}" || true
            else
                bash "$WORKTREE_HELPER" cleanup --quiet || true
            fi
            touch "$(cleanup_stamp_file)"
        fi

        while IFS= read -r repo_dir; do
            [[ -n "$repo_dir" ]] || continue
            repo_path=$(normalize_discovered_path "$(dirname "$repo_dir")")
            if session_matches_repo_path "$repo_path"; then
                continue
            fi
            if ! repo_sync_due "$repo_path"; then
                continue
            fi

            touch "$(repo_refreshing_file "$repo_path")"
            if bash "$WORKTREE_HELPER" sync-repo "$repo_path" >/dev/null 2>&1; then
                clear_repo_warning "$repo_path"
                mark_repo_refreshed "$repo_path"
            else
                mark_repo_warning "$repo_path" "needs cleanup"
            fi
            rm -f "$(repo_refreshing_file "$repo_path")"
        done < <(project_repo_paths)
    ) >/dev/null 2>&1 &
}

prepare_picker_state() {
    load_maintenance_state
    run_background_maintenance
}

prepare_project_launch() {
    local main_path="$1" repo_name="$2"
    local worktree_info

    if session_matches_repo_path "$main_path"; then
        echo ""
        echo "  Cannot start a new session from $repo_name."
        echo "  The base repo still has a live tmux session attached to it."
        echo "  Reattach to that session or exit it first."
        echo ""
        return 1
    fi

    if ! sync_repo_or_warn "$main_path"; then
        worktree_info=$(bash "$WORKTREE_HELPER" recover-dirty-repo "$main_path" 2>/dev/null) || {
            echo ""
            echo "  Cannot start a new session from $repo_name."
            echo "  The base repo is not clean enough to sync to its default branch."
            echo "  Move or commit the in-repo changes first, then retry."
            echo ""
            return 1
        }

        IFS='|' read -r LAUNCH_PATH LAUNCH_BRANCH <<< "$worktree_info"
        LAUNCH_REPO_NAME="$repo_name"
        clear_repo_warning "$main_path"
        mark_repo_refreshed "$main_path"
        bash "$WORKTREE_HELPER" sync-repo "$main_path" >/dev/null 2>&1 || true
        return 0
    fi

    clear_repo_warning "$main_path"
    mark_repo_refreshed "$main_path"

    worktree_info=$(bash "$WORKTREE_HELPER" create-session-worktree "$main_path")
    # shellcheck disable=SC2034  # LAUNCH_* consumed by launch() in start-menu-common.sh
    IFS='|' read -r LAUNCH_PATH LAUNCH_BRANCH _default_branch <<< "$worktree_info"
    # shellcheck disable=SC2034
    LAUNCH_REPO_NAME="$repo_name"
}

before_picker_loop() {
    first_run_check
}

handle_extra_choice() {
    local choice="$1"
    if [[ "$choice" == "h" ]]; then
        launch_shell
        return 0
    fi
    return 1
}

if [[ "${START_MENU_TESTING:-0}" != "1" ]]; then
    run_picker_loop
fi
