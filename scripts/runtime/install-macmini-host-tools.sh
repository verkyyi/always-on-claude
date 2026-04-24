#!/bin/bash
# install-macmini-host-tools.sh — Install Mac mini host CLI tools.

set -euo pipefail

info() { printf '\n=== %s ===\n' "$*"; }
ok() { printf '  OK: %s\n' "$*"; }
skip() { printf '  SKIP: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

HOME_DIR="${AOC_HOME:-$HOME}"
REPO="${AOC_REPO:-$HOME_DIR/always-on-claude}"
BREW="${AOC_BREW:-/opt/homebrew/bin/brew}"
NPM="${AOC_NPM:-/opt/homebrew/bin/npm}"
AWS_DIR="${AOC_AWS_DIR:-$HOME_DIR/aoc-data/aws}"
CODEX_HOME="${CODEX_HOME:-$HOME_DIR/.codex}"

[ -x "$BREW" ] || die "Homebrew not found at $BREW"
[ -x "$NPM" ] || die "npm not found at $NPM"
[ -d "$REPO" ] || die "Repo not found: $REPO"

info "Codex CLI"
if ! command -v codex >/dev/null 2>&1; then
    "$NPM" install -g @openai/codex
    ok "Installed Codex CLI"
else
    skip "Codex CLI already installed"
fi

if [ -x "$REPO/scripts/runtime/sync-codex-personalization.sh" ]; then
    CODEX_HOME="$CODEX_HOME" "$REPO/scripts/runtime/sync-codex-personalization.sh" >/dev/null
    ok "Synced Codex host config"
fi

info "AWS CLI"
if ! command -v aws >/dev/null 2>&1; then
    "$BREW" install awscli
    ok "Installed AWS CLI"
else
    skip "AWS CLI already installed"
fi

mkdir -p "$AWS_DIR"
if [ -e "$HOME_DIR/.aws" ] && [ ! -L "$HOME_DIR/.aws" ]; then
    skip "$HOME_DIR/.aws exists and is not a symlink"
elif [ -L "$HOME_DIR/.aws" ]; then
    current_target="$(readlink "$HOME_DIR/.aws")"
    if [ "$current_target" = "$AWS_DIR" ]; then
        skip "$HOME_DIR/.aws already points to $AWS_DIR"
    else
        die "$HOME_DIR/.aws points to $current_target, expected $AWS_DIR"
    fi
else
    ln -s "$AWS_DIR" "$HOME_DIR/.aws"
    ok "Linked $HOME_DIR/.aws -> $AWS_DIR"
fi

info "Verify"
codex --version
aws --version
