#!/bin/bash
# upgrade-code-agents.sh — Update Claude Code and Codex in a user-writable way.
#
# Intended for container startup. This script must be safe to run as the
# non-root dev user: Claude uses its native user-local updater, and Codex is
# installed into ~/.local so it shadows the root-owned image package.

set -euo pipefail

info() { printf '\n=== %s ===\n' "$*"; }
ok() { printf '  OK: %s\n' "$*"; }
warn() { printf '  WARN: %s\n' "$*" >&2; }

if [[ "${AOC_AUTO_UPGRADE_AGENTS:-1}" == "0" ]]; then
    ok "Agent auto-upgrade disabled"
    exit 0
fi

if [[ "$(id -u)" -eq 0 ]]; then
    warn "Run as the workspace user, not root; skipping agent upgrade"
    exit 0
fi

export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-$HOME/.local}"
export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"

mkdir -p "$NPM_CONFIG_PREFIX/bin" "$HOME/.cache/aoc"

info "Claude Code"
if command -v claude >/dev/null 2>&1; then
    before=$(claude --version 2>/dev/null || true)
    if claude update >/dev/null 2>&1; then
        after=$(claude --version 2>/dev/null || true)
        if [[ -n "$before" && -n "$after" && "$before" != "$after" ]]; then
            ok "$before -> $after"
        else
            ok "${after:-up to date}"
        fi
    else
        warn "Claude update failed; keeping current version${before:+ ($before)}"
    fi
else
    warn "claude is not installed"
fi

info "Codex"
if command -v npm >/dev/null 2>&1; then
    before=$(codex --version 2>/dev/null || true)
    if npm install -g @openai/codex@latest >/dev/null 2>&1; then
        hash -r
        after=$(codex --version 2>/dev/null || true)
        if [[ -n "$before" && -n "$after" && "$before" != "$after" ]]; then
            ok "$before -> $after"
        else
            ok "${after:-up to date}"
        fi
    else
        warn "Codex update failed; keeping current version${before:+ ($before)}"
    fi
else
    warn "npm is not installed"
fi
