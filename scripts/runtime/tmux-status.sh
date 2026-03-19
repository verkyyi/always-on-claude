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

# --- CPU usage ---
if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: aggregate CPU from ps + core count
    cpu_sum=$(ps -A -o %cpu | awk '{s+=$1} END {printf "%.0f", s}')
    ncpu=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
    cpu=$((cpu_sum / ncpu))
else
    # Linux: from /proc/stat, cumulative since boot
    cpu=$(awk '/^cpu / {idle=$5; total=0; for(i=2;i<=NF;i++) total+=$i; printf "%.0f", 100-idle*100/total}' /proc/stat 2>/dev/null)
fi

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
if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: vm_stat + sysctl
    page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
    total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    total=$((total_bytes / 1024 / 1024))
    # Pages: active + wired + compressed ≈ used
    active=$(vm_stat 2>/dev/null | awk '/Pages active/ {gsub(/\./,"",$3); print $3}')
    wired=$(vm_stat 2>/dev/null | awk '/Pages wired/ {gsub(/\./,"",$4); print $4}')
    compressed=$(vm_stat 2>/dev/null | awk '/Pages occupied by compressor/ {gsub(/\./,"",$5); print $5}')
    used_pages=$(( ${active:-0} + ${wired:-0} + ${compressed:-0} ))
    used=$(( used_pages * page_size / 1024 / 1024 ))
elif command -v free &>/dev/null; then
    read -r used total <<< "$(free -m | awk '/Mem:/ {print $3, $2}')"
fi

if [ -n "${used:-}" ] && [ -n "${total:-}" ] && [ "${total:-0}" -gt 0 ]; then
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

# --- Active claude sessions ---
sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -c '^claude-' || echo 0)

# --- Output ---
printf " %s ${DIM}│ ${BLUE}CPU %s ${DIM}│ ${BLUE}MEM %s ${DIM}│ ${BLUE}%s sess ${DIM}│ ${BLUE}%s " \
    "$container" "$cpu_out" "$mem_out" "$sessions" "$(hostname -s 2>/dev/null || echo '?')"
