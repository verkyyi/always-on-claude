#!/bin/bash
# start-claude.sh — Auto-starts the dev container if needed,
# then presents a workspace picker and launches the preferred
# coding assistant inside a named tmux session.
#
# Called automatically from ssh-login.sh on SSH login.

set -euo pipefail

COMPOSE_DIR="${DEV_ENV:-$HOME/dev-env}"
COMMON_LIB="$COMPOSE_DIR/scripts/lib/start-menu-common.sh"

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
WORKTREE_HELPER="$COMPOSE_DIR/scripts/runtime/worktree-helper.sh"
MENU_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/aoc/start-menu"
MENU_SYNC_TTL="${AOC_MENU_SYNC_TTL:-600}"
MENU_CLEANUP_TTL="${AOC_MENU_CLEANUP_TTL:-300}"

COMPOSE_CMD=(sudo --preserve-env=HOME docker compose)
# Shared picker config consumed by scripts/lib/start-menu-common.sh.
# shellcheck disable=SC2034
MANAGER_TARGET="$COMPOSE_DIR"
# shellcheck disable=SC2034
MENU_ACTIONS="h=host  c=container"

# shellcheck source=../lib/start-menu-common.sh
source "$COMMON_LIB"

CODE_AGENT=$(normalize_code_agent "${DEFAULT_CODE_AGENT:-claude}")

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

to_container_path() {
    echo "${1/$HOME\/projects/$CONTAINER_PROJECTS}"
}

launch() {
    local selected="$1"
    local branch="${2:-}"
    local repo_name="${3:-$(basename "$selected")}"
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

    AOC_SESSION_PATH="$selected" \
    AOC_SESSION_REPO="$repo_name" \
    AOC_SESSION_BRANCH="$branch" \
    new_or_attach_tmux_session "$session_name" \
        "docker exec -it -e CLAUDE_MOBILE=\"${CLAUDE_MOBILE:-}\" -e OPENAI_API_KEY=\"${OPENAI_API_KEY:-}\" -e ANTHROPIC_API_KEY=\"${ANTHROPIC_API_KEY:-}\" -e DEFAULT_CODE_AGENT=\"$CODE_AGENT\" -w '$container_path' ${CONTAINER_NAME} bash -lc 'exec bash \"$RUNNER_CONTAINER\" --agent \"$CODE_AGENT\" --resume-latest'"
}

launch_manager() {
    local dir="$1"
    local session_name="claude-manager"

    # Check session limit (allows re-attach, blocks new if at limit)
    if ! check_session_limit "$session_name"; then
        return 1
    fi

    echo "  -> $dir (host)"
    echo ""

    new_or_attach_tmux_session "$session_name" \
        "bash -lc 'exec bash \"$RUNNER_HOST\" --agent claude --cwd \"$dir\" --prompt-file \"$MANAGER_PROMPT\" --message \"Greet me and show what you can help with.\"'"
}

launch_shell_host() {
    echo "  -> host shell"
    echo ""
    new_or_attach_tmux_session "shell-host" "bash -l"
}

launch_shell_container() {
    echo "  -> container shell"
    echo ""
    new_or_attach_tmux_session "shell-container" \
        "docker exec -it ${CONTAINER_NAME} bash -l"
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

    wait_for_container

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

prepare_manager_launch() {
    wait_for_container
}

before_picker_loop() {
    ensure_container_bg
}

handle_extra_choice() {
    local choice="$1"
    if [[ "$choice" == "h" ]]; then
        launch_shell_host
        return 0
    elif [[ "$choice" == "c" ]]; then
        wait_for_container || return 0
        launch_shell_container
        return 0
    fi
    return 1
}

if [[ "${START_MENU_TESTING:-0}" != "1" ]]; then
    run_picker_loop
fi
