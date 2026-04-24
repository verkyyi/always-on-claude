#!/usr/bin/env bash
# statusline-command.sh — Claude Code status line: model + context % + effort
#
# Shows: Opus  72% 720k  high
#   - Model name (shortened)
#   - Context remaining (green >30%, yellow 10-30%, red <10%)
#   - Effort level from settings

input=$(cat)

remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
model_id=$(echo "$input" | jq -r '.model.id // ""')
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
effort=$(jq -r '.effortLevel // "normal"' ~/.claude/settings.json 2>/dev/null || echo "normal")

hash_path() {
    if command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$1" | md5sum | awk '{print $1}'
    elif command -v md5 >/dev/null 2>&1; then
        printf '%s' "$1" | md5 -q
    else
        printf '%s' "$1" | cksum | awk '{print $1}'
    fi
}

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

# Git branch + repo counts (issues/PRs) are read from cache. If the cache is
# stale, refresh it asynchronously so the status line itself stays fast.
branch_state=""
repo_state=""
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
    repo_dir=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$repo_dir" ]; then
        branch=$(git -C "$repo_dir" symbolic-ref --short HEAD 2>/dev/null \
            || git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null \
            || true)
        if [ -n "$branch" ]; then
            branch_state="  ${CYAN}${branch}${RESET}"
        fi

        hash=$(hash_path "$repo_dir")
        cache="$HOME/.claude/cache/repo-status/${hash}.txt"
        now=$(date +%s)
        ts=0
        if [ -f "$cache" ]; then
            ts=$(awk -F= '/^ts=/{print $2}' "$cache" 2>/dev/null)
            issues=$(awk -F= '/^issues=/{print $2}' "$cache" 2>/dev/null)
            prs=$(awk -F= '/^prs=/{print $2}' "$cache" 2>/dev/null)
            if [ -n "${issues:-}" ] || [ -n "${prs:-}" ]; then
                repo_state="  ${YELLOW}${issues:-?}i${RESET}/${CYAN}${prs:-?}p${RESET}"
            fi
        fi

        case "${ts:-}" in
            ''|*[!0-9]*) ts=0 ;;
        esac
        age=$(( now - ts ))
        refresh_script="$HOME/.claude/hooks/repo-counts-refresh.sh"
        if [ "$age" -gt 300 ] && [ -x "$refresh_script" ]; then
            ( nohup bash "$refresh_script" "$repo_dir" \
                >/dev/null 2>&1 </dev/null & ) >/dev/null 2>&1
        fi
    fi
fi

printf "${CYAN}%s${RESET}  %s  ${CYAN}%s${RESET}%s%s\n" "$model" "$ctx" "$effort" "$branch_state" "$repo_state"
