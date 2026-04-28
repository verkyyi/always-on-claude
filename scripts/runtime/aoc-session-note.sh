#!/bin/bash
# aoc-session-note.sh — Set or show a short note for the current tmux session.

set -euo pipefail

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ -n "${TMUX:-}" ]] || die "run this inside a tmux session"

session_name=$(tmux display-message -p '#S')

if [[ $# -eq 0 ]]; then
    tmux show-option -t "$session_name" -qv @aoc_note
    exit 0
fi

if [[ "$1" == "--clear" ]]; then
    tmux set-option -t "$session_name" -qu @aoc_note
    echo "cleared"
    exit 0
fi

note="$*"
tmux set-option -t "$session_name" -q @aoc_note "$note"
echo "$note"
