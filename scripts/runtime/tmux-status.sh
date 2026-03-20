#!/bin/bash
# tmux-status.sh — Right side of the tmux status bar
#
# Shows: 2/3 sess

BLUE="#[fg=#7aa2f7]"

sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -c '^claude-' || echo 0)

# Calculate max sessions (same formula as start-claude.sh)
if [[ -n "${MAX_SESSIONS:-}" ]]; then
    max=$MAX_SESSIONS
else
    if [[ -f /proc/meminfo ]]; then
        total_mem_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    elif command -v sysctl &>/dev/null; then
        total_mem_mb=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}')
    else
        total_mem_mb=4096
    fi
    cpus=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
    mem_based=$(( (total_mem_mb - 1024) / 650 ))
    [[ $mem_based -lt 1 ]] && mem_based=1
    max=$(( mem_based < cpus ? mem_based : cpus ))
    [[ $max -lt 1 ]] && max=1
fi

printf " ${BLUE}%s/%s sess " "$sessions" "$max"
