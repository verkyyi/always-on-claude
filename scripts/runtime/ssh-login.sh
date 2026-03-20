#!/bin/bash
# ssh-login.sh — Source this from .bash_profile.
# Launches Claude Code workspace picker on SSH login.
#
# Multi-user aware: detects the current Linux user and routes to
# the correct container (claude-dev for single-user, claude-dev-<user>
# for multi-user setups).
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
    echo "  Updates available — run /update in Claude to apply."
fi

if [[ -f /run/disk-monitor.warning ]]; then
    echo ""
    echo "  $(cat /run/disk-monitor.warning)"
fi

# Resolve the dev-env path (symlink for multi-user, direct for single-user)
DEV_ENV="${HOME}/dev-env"
if [[ -L "$DEV_ENV" ]]; then
    DEV_ENV="$(readlink -f "$DEV_ENV")"
fi

# Detect multi-user mode: if current user is not 'dev' and has a
# per-user container, route to it
CLAUDE_USER=""
USERS_BASE="/home/dev/users"
USERS_CONF="$USERS_BASE/.users.conf"

if [[ "$USER" != "dev" && -f "$USERS_CONF" ]]; then
    if grep -q "^${USER}|" "$USERS_CONF" 2>/dev/null; then
        CLAUDE_USER="$USER"
        export CLAUDE_USER
        export CLAUDE_CONTAINER="claude-dev-${USER}"
        export CLAUDE_USER_HOME="$USERS_BASE/$USER"
    fi
fi

if [[ -x "$DEV_ENV/scripts/runtime/start-claude.sh" ]]; then
    exec bash "$DEV_ENV/scripts/runtime/start-claude.sh"
else
    # Try the canonical path as fallback
    if [[ -x /home/dev/dev-env/scripts/runtime/start-claude.sh ]]; then
        exec bash /home/dev/dev-env/scripts/runtime/start-claude.sh
    else
        echo "  start-claude.sh not found"
    fi
fi
