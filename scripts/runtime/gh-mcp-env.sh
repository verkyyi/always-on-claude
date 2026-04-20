#!/usr/bin/env bash
# gh-mcp-env.sh — Exports GITHUB_PERSONAL_ACCESS_TOKEN from gh CLI auth state so
# the github MCP server (https://api.githubcopilot.com/mcp/) activates for the
# Claude session. No-op (with a one-line stderr hint) if gh isn't installed or
# isn't authed.
#
# Sourced by start-claude*.sh just before exec'ing claude.
#
# Safe to source under `set -e`: the conditional consumes the exit status, so a
# missing or unauthed gh never aborts the caller.

if command -v gh &>/dev/null && gh auth status &>/dev/null; then
    export GITHUB_PERSONAL_ACCESS_TOKEN="$(gh auth token 2>/dev/null)"
else
    echo "ℹ GitHub MCP inactive — run 'gh auth login' to enable agent GitHub tools" >&2
fi
