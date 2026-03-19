#!/bin/bash
# tmux-status.sh — Right side of the tmux status bar
#
# Shows: 3 sess

BLUE="#[fg=#7aa2f7]"

sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -c '^claude-' || echo 0)

printf " ${BLUE}%s sess " "$sessions"
