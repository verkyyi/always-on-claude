#!/bin/bash
# tmux-status.sh — Right side of the tmux status bar
#
# Shows: 1/3  62%

DIM="#[fg=#565f89]"

# Session count
sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -Ec '^(claude|codex)-' || true)

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

# Memory usage
if [[ -f /proc/meminfo ]]; then
    mem_pct=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%.0f", (t-a)/t*100}' /proc/meminfo)
elif command -v vm_stat &>/dev/null; then
    mem_pct=$(vm_stat | awk '/Pages active/{a=$3} /Pages wired/{w=$4} /Pages free/{f=$3} /Pages speculative/{s=$3} END{gsub(/\./,"",a); gsub(/\./,"",w); gsub(/\./,"",f); gsub(/\./,"",s); printf "%.0f", (a+w)/(a+w+f+s)*100}')
else
    mem_pct="?"
fi

printf "${DIM}%s/%s  %s%% " "$sessions" "$max" "$mem_pct"
