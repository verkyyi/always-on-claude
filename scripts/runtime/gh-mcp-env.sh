#!/usr/bin/env bash
# gh-mcp-env.sh — Exports GITHUB_PERSONAL_ACCESS_TOKEN from gh CLI auth state so
# the github MCP server (https://api.githubcopilot.com/mcp/) activates for the
# Claude session. No-op (with a one-line stderr hint) if gh isn't installed,
# isn't authed, or returns an empty token.
#
# Sourced by start-claude*.sh just before exec'ing claude.
#
# Safe to source under `set -e`: every failure path flows through an `if`
# conditional that consumes the exit status, so the caller is never aborted.

if command -v gh &>/dev/null && gh auth status &>/dev/null; then
    _gh_mcp_token="$(gh auth token 2>/dev/null || true)"
    if [[ -n "$_gh_mcp_token" ]]; then
        export GITHUB_PERSONAL_ACCESS_TOKEN="$_gh_mcp_token"
    else
        echo "info: GitHub MCP inactive - 'gh auth token' returned nothing; try 'gh auth refresh'" >&2
    fi
    unset _gh_mcp_token
else
    echo "info: GitHub MCP inactive - run 'gh auth login' to enable agent GitHub tools" >&2
fi
