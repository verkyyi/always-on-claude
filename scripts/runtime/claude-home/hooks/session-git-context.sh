#!/usr/bin/env bash
# SessionStart hook: warm the status line repo-count cache without blocking.

set -u

cat >/dev/null

git rev-parse --git-dir >/dev/null 2>&1 || exit 0
git remote get-url origin >/dev/null 2>&1 || exit 0

( nohup bash "$HOME/.claude/hooks/repo-counts-refresh.sh" "$(pwd)" \
    >/dev/null 2>&1 </dev/null & ) >/dev/null 2>&1

exit 0
