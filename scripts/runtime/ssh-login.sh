#!/bin/bash
# ssh-login.sh — Source this from .bash_profile.
# Launches Claude Code workspace picker on SSH login.
#
# Skips when:
#   - Already inside tmux
#   - Non-interactive shell (scp, rsync, etc.)
#   - NO_CLAUDE=1 env var is set

# Guard: only run for interactive, non-tmux, SSH sessions
[[ $- != *i* ]] && return
[[ -n "${TMUX:-}" ]] && return
[[ -z "${SSH_CONNECTION:-}" ]] && return
[[ "${NO_CLAUDE:-}" == "1" ]] && return

# Detect narrow terminal (likely mobile SSH client)
if [[ "$(tput cols 2>/dev/null || echo 80)" -lt 60 ]]; then
    export CLAUDE_MOBILE=1
fi

if [[ -f ~/.update-pending ]]; then
    echo ""
    echo "  Updates available — run /update in Claude to apply."
fi

if [[ -f ~/.claude-version-check ]]; then
    _cv_status=""
    _cv_installed=""
    _cv_latest=""
    while IFS='=' read -r key val; do
        case "$key" in
            status)    _cv_status="$val" ;;
            installed) _cv_installed="$val" ;;
            latest)    _cv_latest="$val" ;;
        esac
    done < ~/.claude-version-check
    if [[ "$_cv_status" == "update-available" ]]; then
        echo "  Claude Code update: ${_cv_installed} -> ${_cv_latest}"
        echo "  Run /update-claude-code to update, or set CLAUDE_AUTO_UPDATE=1"
    fi
    unset _cv_status _cv_installed _cv_latest
fi

# First-run onboarding: guide new users through setup before workspace picker
if [[ ! -f ~/.workspace-initialized ]]; then
    if [[ -x ~/dev-env/scripts/runtime/onboarding.sh ]]; then
        exec bash ~/dev-env/scripts/runtime/onboarding.sh
    else
        echo "  ⚠ onboarding.sh not found or not executable — skipping first-run setup"
    fi
fi

if [[ -x ~/dev-env/scripts/runtime/start-claude.sh ]]; then
    exec bash ~/dev-env/scripts/runtime/start-claude.sh
else
    echo "  ⚠ start-claude.sh not found at ~/dev-env/scripts/runtime/start-claude.sh"
fi
