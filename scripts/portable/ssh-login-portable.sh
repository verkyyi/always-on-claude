#!/bin/bash
# ssh-login-portable.sh — Source this from .bash_profile inside the portable container.
# Launches Claude Code workspace picker on login (Tailscale SSH or docker exec).
#
# Unlike the host-mode ssh-login.sh, this runs INSIDE the container —
# no docker exec needed.
#
# Skips when:
#   - Already inside tmux
#   - Non-interactive shell (scp, rsync, etc.)
#   - NO_CLAUDE=1 env var is set
#
# NOTE: No `set -euo pipefail` — this file is sourced from .bash_profile,
# so strict error handling would kill the user's login shell on any failure.

# Guard: only run for interactive, non-tmux sessions
[[ $- != *i* ]] && return
[[ -n "${TMUX:-}" ]] && return
[[ "${NO_CLAUDE:-}" == "1" ]] && return

if [[ -f ~/.update-pending ]]; then
    echo ""
    echo "  Updates available — run /update in Claude to apply."
fi

if [[ -x ~/dev-env/scripts/portable/start-claude-portable.sh ]]; then
    exec bash ~/dev-env/scripts/portable/start-claude-portable.sh
else
    echo "  start-claude-portable.sh not found — launching claude directly"
    exec claude
fi
