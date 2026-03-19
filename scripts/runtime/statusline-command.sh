#!/usr/bin/env bash
# statusline-command.sh — Claude Code status line
#
# Shows: Opus  72% 720k  high  local  1 host
#   - Model name (shortened)
#   - Context remaining (green >30%, yellow 10-30%, red <10%)
#   - Effort level from settings
#   - Environment: local (Mac) or remote (EC2 container)
#   - Instance count: running EC2 hosts (local only, cached 5 min)

input=$(cat)

remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
model_id=$(echo "$input" | jq -r '.model.id // ""')
effort=$(jq -r '.effortLevel // "normal"' ~/.claude/settings.json 2>/dev/null || echo "normal")

# ANSI color codes
RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
RESET=$'\033[0m'

# Shorten model name
case "$model_id" in
  *opus*)   model="Opus" ;;
  *sonnet*) model="Sonnet" ;;
  *haiku*)  model="Haiku" ;;
  *)        model=$(echo "$input" | jq -r '.model.display_name // "Claude"') ;;
esac

# Context percentage + absolute tokens with color
if [ -n "$remaining" ] && [ "$remaining" != "null" ]; then
    pct=$(printf "%.0f" "$remaining")
    # Calculate remaining tokens in k
    if [ -n "$ctx_size" ] && [ "$ctx_size" != "null" ]; then
        remaining_tokens=$(awk "BEGIN {printf \"%.0f\", $ctx_size * $remaining / 100 / 1000}")
        tokens="${remaining_tokens}k"
    else
        tokens=""
    fi
    if [ "$pct" -le 10 ]; then
        color="$RED"
    elif [ "$pct" -le 30 ]; then
        color="$YELLOW"
    else
        color="$GREEN"
    fi
    ctx="${color}${pct}% ${tokens}${RESET}"
else
    ctx="${CYAN}–${RESET}"
fi

# Detect environment
if [[ "$(uname -s)" == "Darwin" ]]; then
    env_label="local"
elif [[ "$(hostname)" == "claude-dev" || -d /home/dev ]]; then
    env_label="remote"
else
    env_label=""
fi

# Instance count (local Mac only, cached 5 min)
instance_count=""
if [[ "$env_label" == "local" ]] && command -v aws &>/dev/null; then
    cache_file="/tmp/.aoc-instance-count"
    cache_max=300
    now=$(date +%s)
    if [[ -f "$cache_file" ]]; then
        cache_age=$(( now - $(stat -f %m "$cache_file" 2>/dev/null || echo 0) ))
    else
        cache_age=$((cache_max + 1))
    fi
    if [[ $cache_age -gt $cache_max ]]; then
        count=$(aws ec2 describe-instances \
            --filters "Name=tag:Project,Values=always-on-claude" \
                      "Name=instance-state-name,Values=running" \
            --query 'Reservations[].Instances[] | length(@)' \
            --output text 2>/dev/null || echo "?")
        echo "$count" > "$cache_file" 2>/dev/null
    else
        count=$(cat "$cache_file" 2>/dev/null || echo "?")
    fi
    if [[ "$count" =~ ^[0-9]+$ ]]; then
        instance_count="${GREEN}${count} host$( [[ "$count" != "1" ]] && echo "s" || true)${RESET}"
    fi
fi

# Build output
suffix=""
[[ -n "$env_label" ]] && suffix="  ${CYAN}${env_label}${RESET}"
[[ -n "$instance_count" ]] && suffix="${suffix}  ${instance_count}"

printf "${CYAN}%s${RESET}  %s  ${CYAN}%s${RESET}%s\n" "$model" "$ctx" "$effort" "$suffix"
