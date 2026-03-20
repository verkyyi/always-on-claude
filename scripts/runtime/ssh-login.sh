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

if [[ -f ~/.update-pending ]]; then
    echo ""
    if grep -q "restart_pending=" ~/.update-pending 2>/dev/null; then
        echo "  Restart pending — a new image is ready. Container will restart when sessions end."
        echo "  Or run: bash ~/dev-env/scripts/runtime/rolling-update.sh --force"
    else
        echo "  Updates available — run /update in Claude to apply."
    fi
fi

if [[ -x ~/dev-env/scripts/runtime/start-claude.sh ]]; then
    exec bash ~/dev-env/scripts/runtime/start-claude.sh
else
    echo "  ⚠ start-claude.sh not found at ~/dev-env/scripts/runtime/start-claude.sh"
fi
