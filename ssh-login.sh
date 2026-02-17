#!/bin/bash
# ssh-login.sh — Source this from .bash_profile.
# Shows an interactive menu on SSH login to choose Claude Code,
# a container shell, or the host shell.
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
echo "  │  [1] Claude Code            │"
echo "  │  [2] Container bash         │"
echo "  │  [3] Host shell             │"
echo "  └─────────────────────────────┘"
echo ""

choice=""
read -n 1 -p "  > " choice || true
echo ""

case "$choice" in
    2)
        exec tmux new-session -A -s dev \
            "docker exec -it claude-dev bash -l"
        ;;
    3)
        exec tmux new-session -A -s host
        ;;
    *)
        if [[ -x ~/dev-env/start-claude.sh ]]; then
            exec bash ~/dev-env/start-claude.sh
        else
            echo "  ⚠ start-claude.sh not found at ~/dev-env/start-claude.sh"
        fi
        ;;
esac
