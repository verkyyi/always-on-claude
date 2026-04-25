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

# shellcheck source=../lib/start-menu-common.sh
source "$COMMON_LIB"

CODE_AGENT=$(normalize_code_agent "${DEFAULT_CODE_AGENT:-claude}")

all_menu_session_pattern() {
    echo '^((claude|codex)-|shell-)'
}

menu_session_pattern() {
    all_menu_session_pattern
}

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

launch_shell() {
    echo "  -> shell"
    echo ""
    tmux new-session -A -s "shell-local" "bash -l"
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
