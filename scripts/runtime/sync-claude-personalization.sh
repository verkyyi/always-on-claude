#!/bin/bash
# sync-claude-personalization.sh — Materialize repo-managed Claude user state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_HOME="$SCRIPT_DIR/claude-home"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

CHANGED=0

sync_file() {
    local src="$1"
    local dest="$2"
    local mode="$3"

    mkdir -p "$(dirname "$dest")"

    if [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; then
        cp "$src" "$dest"
        CHANGED=1
    fi

    chmod "$mode" "$dest"
}

if [[ -d "$SOURCE_HOME/commands" ]]; then
    while IFS= read -r -d '' src; do
        rel="${src#"$SOURCE_HOME/"}"
        sync_file "$src" "$CLAUDE_HOME/$rel" 644
    done < <(find "$SOURCE_HOME/commands" -type f -print0)
fi

if [[ -d "$SOURCE_HOME/skills" ]]; then
    while IFS= read -r -d '' src; do
        rel="${src#"$SOURCE_HOME/"}"
        sync_file "$src" "$CLAUDE_HOME/$rel" 644
    done < <(find "$SOURCE_HOME/skills" -type f -print0)
fi

if [[ "$CHANGED" -eq 1 ]]; then
    echo "updated"
else
    echo "unchanged"
fi
