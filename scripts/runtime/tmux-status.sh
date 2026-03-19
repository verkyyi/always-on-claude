#!/bin/bash
# tmux-status.sh — Right side of the tmux status bar
#
# Shows: ● CPU 23% │ MEM 1.2G/4G │ 3 sessions │ hostname
#
# Color coding:
#   CPU:  green <50%, yellow 50-80%, red >80%
#   MEM:  green <60%, yellow 60-85%, red >85%
#   Container: green ● running, red ○ stopped

# Palette (Tokyo Night)
RED="#[fg=#f7768e]"
YELLOW="#[fg=#e0af68]"
GREEN="#[fg=#9ece6a]"
BLUE="#[fg=#7aa2f7]"
DIM="#[fg=#565f89]"

# --- Container status ---
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^claude-dev$"; then
    container="${GREEN}●"
else
    container="${RED}○"
fi

# --- CPU usage (from /proc/stat, cumulative since boot) ---
cpu=$(awk '/^cpu / {idle=$5; total=0; for(i=2;i<=NF;i++) total+=$i; printf "%.0f", 100-idle*100/total}' /proc/stat 2>/dev/null)
if [ -n "$cpu" ]; then
    if [ "$cpu" -ge 80 ]; then
        cpu_out="${RED}${cpu}%"
    elif [ "$cpu" -ge 50 ]; then
        cpu_out="${YELLOW}${cpu}%"
    else
        cpu_out="${GREEN}${cpu}%"
    fi
else
    cpu_out="${DIM}–"
fi

# --- Memory usage ---
if command -v free &>/dev/null; then
    read -r used total <<< "$(free -m | awk '/Mem:/ {print $3, $2}')"
    if [ -n "$used" ] && [ -n "$total" ] && [ "$total" -gt 0 ]; then
        mem_pct=$((used * 100 / total))
        mem_display=$(awk "BEGIN {printf \"%.1fG/%.1fG\", $used/1024, $total/1024}")
        if [ "$mem_pct" -ge 85 ]; then
            mem_out="${RED}${mem_display}"
        elif [ "$mem_pct" -ge 60 ]; then
            mem_out="${YELLOW}${mem_display}"
        else
            mem_out="${GREEN}${mem_display}"
        fi
    else
        mem_out="${DIM}–"
    fi
else
    mem_out="${DIM}–"
fi

# --- Active claude sessions ---
sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -c '^claude-' || echo 0)

# --- Output ---
printf " %s ${DIM}│ ${BLUE}CPU %s ${DIM}│ ${BLUE}MEM %s ${DIM}│ ${BLUE}%s sess ${DIM}│ ${BLUE}%s " \
    "$container" "$cpu_out" "$mem_out" "$sessions" "$(hostname -s 2>/dev/null || echo '?')"
