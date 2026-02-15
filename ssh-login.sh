#!/bin/bash
# ssh-login.sh — Source this from .bash_profile.
# Shows an interactive menu on SSH login with auto-default to Claude Code.
#
# Skips the prompt when:
#   - Already inside tmux
#   - Non-interactive shell (scp, rsync, etc.)
#   - NO_CLAUDE=1 env var is set

# Guard: only run for interactive, non-tmux, SSH sessions
[[ $- != *i* ]] && return
[[ -n "${TMUX:-}" ]] && return
[[ -z "${SSH_CONNECTION:-}" ]] && return
[[ "${NO_CLAUDE:-}" == "1" ]] && return

echo ""
echo "  ┌─────────────────────────────┐"
echo "  │  [1] Claude Code (3s)       │"
echo "  │  [2] Plain shell            │"
echo "  └─────────────────────────────┘"
echo ""

choice=""
read -t 3 -n 1 -p "  > " choice || true
echo ""

case "$choice" in
    2)
        echo "  → Shell. Happy hacking!"
        echo ""
        ;;
    *)
        exec bash ~/dev-env/start-claude.sh
        ;;
esac
