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

launch_manager() {
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

launch_shell_host() {
    echo "  -> host shell"
    echo ""
    tmux new-session -A -s "shell-host" "bash -l"
}

launch_shell_container() {
    echo "  -> container shell"
    echo ""
    tmux new-session -A -s "shell-container" \
        "docker exec -it ${CONTAINER_NAME} bash -l"
}

prepare_project_launch() {
    wait_for_container
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
        prepare_project_launch || return 0
        launch_shell_container
        return 0
    fi
    return 1
}

if [[ "${START_MENU_TESTING:-0}" != "1" ]]; then
    run_picker_loop
fi
