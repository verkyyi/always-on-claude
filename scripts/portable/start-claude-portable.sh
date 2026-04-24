#!/bin/bash
# start-claude-portable.sh — Workspace picker for portable (single-container) mode.
#
# Unlike the host-mode start-claude.sh, this runs INSIDE the container.
# No docker exec — launches the preferred coding assistant directly in tmux.
#
# Layer 1: Pick a repo (or manage workspaces)
# Layer 2: Pick a branch/worktree within that repo (skipped if no worktrees)
#
# Called automatically from ssh-login-portable.sh on login.

set -euo pipefail

CONFIG_ROOT="${DEV_ENV:-$HOME/dev-env}"

if [[ -f "$CONFIG_ROOT/scripts/deploy/load-config.sh" ]]; then
    # shellcheck disable=SC1091
    source "$CONFIG_ROOT/scripts/deploy/load-config.sh"
fi

DEV_ENV="${DEV_ENV:-$CONFIG_ROOT}"
WORKTREE_HELPER="$DEV_ENV/scripts/runtime/worktree-helper.sh"
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

# --- Layer 1: Pick a repo ---

show_repos() {
    local next_agent
    next_agent=$(next_code_agent "${CODE_AGENT:-${DEFAULT_CODE_AGENT:-claude}}")

    # Collect active code-agent and shell tmux sessions
    # Note: all_sessions is intentionally global — read by reattach_session()
    all_sessions=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && all_sessions+=("$line")
    done < <(tmux list-sessions -F '#{session_name} #{?session_attached,(attached),(idle)}' 2>/dev/null \
        | grep -E '^((claude|codex)-|shell-)' || true)

    if [[ ${#all_sessions[@]} -gt 0 ]]; then
        echo ""
        echo "  === Active sessions ==="
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
        local short_path="${path#"$HOME"/}"
        echo "  [$i] ${short_path} (${branch})"
        ((i++))
    done

    if [[ ${#repos[@]} -eq 0 ]]; then
        echo "  (no repos found — press [m] to clone your first repo)"
    fi

    echo "  Default agent: $CODE_AGENT"
    echo "  [t] Toggle default -> $next_agent"
    echo "  [m] Manage workspaces"
    echo "  [h] Shell"
    echo ""
}

# --- Layer 2: Pick a branch/worktree within a repo ---

show_branches() {
    local repo_path="$1" repo_branch="$2"
    local short_path="${repo_path#"$HOME"/}"

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

# --- Launch the preferred code agent directly in tmux (no docker exec) ---

launch() {
    local selected="$1"

    echo "  -> $selected"
    echo ""

    # Create unique tmux session name
    session_name="${CODE_AGENT}-$(basename "$selected" | tr './:' '-')"

    exec tmux new-session -A -s "$session_name" \
        "bash -lc 'exec bash \"$RUNNER\" --agent \"$CODE_AGENT\" --cwd \"$selected\"'"
}

# --- Launch Claude for workspace management ---

launch_manager() {
    local dir="$1"

    echo "  -> workspace manager"
    echo ""

    exec tmux new-session -A -s "claude-manager" \
        "bash -lc 'exec bash \"$RUNNER\" --agent claude --cwd \"$dir\" --prompt-file \"$MANAGER_PROMPT\" --message \"Greet me and show what you can help with.\"'"
}

# --- Launch a shell in tmux ---
launch_shell() {
    echo "  -> shell"
    echo ""
    exec tmux new-session -A -s "shell-local" "bash -l"
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

first_run_check
discover

# Layer 1 loop
while true; do
    show_repos

    read -r -p "  > " choice || true

    if [[ "$choice" == "m" ]]; then
        launch_manager "$DEV_ENV"
    elif [[ "$choice" == "t" ]]; then
        toggle_code_agent
        continue
    elif [[ "$choice" == "h" ]]; then
        launch_shell
    elif [[ "$choice" =~ ^a([0-9]+)$ ]]; then
        reattach_session "${BASH_REMATCH[1]}" || continue
    elif [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#repos[@]}" ]]; then
        IFS='|' read -r selected_path selected_branch <<< "${repos[$((choice - 1))]}"
    elif [[ -z "$choice" ]]; then
        # Default: first repo, or projects dir if none
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

        read -r -p "  > " choice2 || true

        if [[ "$choice2" == "b" ]]; then
            break  # Back to Layer 1
        elif [[ "$choice2" == "1" || -z "$choice2" ]]; then
            # Main repo
            launch "$selected_path"
        elif [[ "$choice2" =~ ^[0-9]+$ && "$choice2" -ge 2 && "$choice2" -le $(( ${#worktrees[@]} + 1 )) ]]; then
            IFS='|' read -r wt_selected _ <<< "${worktrees[$((choice2 - 2))]}"
            launch "$wt_selected"
        fi
    done
done
