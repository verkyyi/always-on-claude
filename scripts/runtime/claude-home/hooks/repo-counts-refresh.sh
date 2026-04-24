#!/usr/bin/env bash
# Fetch open issue/PR counts for a repo and cache them for the status line.

set -u

CWD="${1:-$(pwd)}"
[[ -d "$CWD" ]] || exit 0

REPO_DIR=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$REPO_DIR" ]] || exit 0

hash_path() {
    if command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$1" | md5sum | awk '{print $1}'
    elif command -v md5 >/dev/null 2>&1; then
        printf '%s' "$1" | md5 -q
    else
        printf '%s' "$1" | cksum | awk '{print $1}'
    fi
}

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 8 "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 8 "$@"
    else
        "$@"
    fi
}

CACHE_DIR="$HOME/.claude/cache/repo-status"
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0

HASH=$(hash_path "$REPO_DIR")
CACHE="$CACHE_DIR/${HASH}.txt"
LOCK="${CACHE}.lock"

ISSUES=""
PRS=""

write_cache() {
    {
        printf 'repo=%s\n' "$REPO_DIR"
        printf 'issues=%s\n' "$ISSUES"
        printf 'prs=%s\n' "$PRS"
        printf 'ts=%s\n' "$(date +%s)"
    } > "$CACHE"
}

mkdir "$LOCK" 2>/dev/null || exit 0
cleanup() {
    write_cache
    rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT

git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
gh auth status >/dev/null 2>&1 || exit 0

ISSUES=$(cd "$REPO_DIR" && run_with_timeout gh issue list --state open --limit 200 \
    --json number 2>/dev/null | jq 'length' 2>/dev/null || echo "")
PRS=$(cd "$REPO_DIR" && run_with_timeout gh pr list --state open --limit 200 \
    --json number 2>/dev/null | jq 'length' 2>/dev/null || echo "")
