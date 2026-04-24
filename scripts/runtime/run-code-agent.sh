#!/bin/bash
# run-code-agent.sh — Launch the configured coding assistant.
#
# Supports:
#   - Claude Code (`claude`)
#   - Codex (`codex`)
#
# Usage:
#   bash run-code-agent.sh [--agent claude|codex] [--cwd DIR] \
#       [--prompt-file FILE] [--message TEXT]

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

normalize_code_agent() {
    case "${1:-}" in
        codex) echo "codex" ;;
        claude|"") echo "claude" ;;
        *) echo "claude" ;;
    esac
}

agent="${DEFAULT_CODE_AGENT:-claude}"
cwd=""
prompt_file=""
message=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)
            [[ $# -ge 2 ]] || die "--agent requires a value"
            agent="$2"
            shift 2
            ;;
        --cwd)
            [[ $# -ge 2 ]] || die "--cwd requires a value"
            cwd="$2"
            shift 2
            ;;
        --prompt-file)
            [[ $# -ge 2 ]] || die "--prompt-file requires a value"
            prompt_file="$2"
            shift 2
            ;;
        --message)
            [[ $# -ge 2 ]] || die "--message requires a value"
            message="$2"
            shift 2
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

agent=$(normalize_code_agent "$agent")

if [[ -n "$cwd" ]]; then
    cd "$cwd"
fi

command -v "$agent" >/dev/null 2>&1 || die "$agent is not installed"

if [[ "$agent" == "claude" ]]; then
    args=()
    if [[ -n "$prompt_file" ]]; then
        [[ -f "$prompt_file" ]] || die "Prompt file not found: $prompt_file"
        args+=(--append-system-prompt-file "$prompt_file")
    fi

    if [[ -n "$message" ]]; then
        exec claude "${args[@]}" "$message"
    fi

    exec claude "${args[@]}"
fi

combined_prompt=""
if [[ -n "$prompt_file" ]]; then
    [[ -f "$prompt_file" ]] || die "Prompt file not found: $prompt_file"
    combined_prompt="$(cat "$prompt_file")"
fi

if [[ -n "$message" ]]; then
    if [[ -n "$combined_prompt" ]]; then
        combined_prompt="${combined_prompt}

${message}"
    else
        combined_prompt="$message"
    fi
fi

if [[ -n "$combined_prompt" ]]; then
    exec codex "$combined_prompt"
fi

exec codex
