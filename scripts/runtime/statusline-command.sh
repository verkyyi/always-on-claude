#!/usr/bin/env bash
# statusline-command.sh — Claude Code status line: model + context % + effort
#
# Shows: Opus  72% 720k  high
#   - Model name (shortened)
#   - Context remaining (green >30%, yellow 10-30%, red <10%)
#   - Effort level from settings

set -euo pipefail

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
if [[ -n "$remaining" && "$remaining" != "null" ]]; then
    pct=$(printf "%.0f" "$remaining")
    if [[ -n "$ctx_size" && "$ctx_size" != "null" ]]; then
        remaining_tokens=$(awk "BEGIN {printf \"%.0f\", $ctx_size * $remaining / 100 / 1000}")
        tokens="${remaining_tokens}k"
    else
        tokens=""
    fi
    if [[ "$pct" -le 10 ]]; then
        color="$RED"
    elif [[ "$pct" -le 30 ]]; then
        color="$YELLOW"
    else
        color="$GREEN"
    fi
    ctx="${color}${pct}% ${tokens}${RESET}"
else
    ctx="${CYAN}-${RESET}"
fi

printf "${CYAN}%s${RESET}  %s  ${CYAN}%s${RESET}\n" "$model" "$ctx" "$effort"
