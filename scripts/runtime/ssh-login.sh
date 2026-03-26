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

_DEV_ENV="${DEV_ENV:-$HOME/dev-env}"

# First-run onboarding: guide new users through setup before workspace picker
if [[ ! -f ~/.workspace-initialized ]]; then
    if [[ -x "$_DEV_ENV/scripts/runtime/onboarding.sh" ]]; then
        exec bash "$_DEV_ENV/scripts/runtime/onboarding.sh"
    else
        echo "  onboarding.sh not found or not executable — skipping first-run setup"
    fi
fi

if [[ -x "$_DEV_ENV/scripts/runtime/start-claude.sh" ]]; then
    exec bash "$_DEV_ENV/scripts/runtime/start-claude.sh"
else
    echo "  start-claude.sh not found at $_DEV_ENV/scripts/runtime/start-claude.sh"
fi
