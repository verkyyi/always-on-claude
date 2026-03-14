#!/bin/bash
# setup-auth.sh — In-container auth helper.
# Run via: docker compose exec dev bash ~/dev-env/setup-auth.sh
#
# Handles git config, GitHub CLI auth, and Claude Code login.
# Idempotent — skips steps that are already done.

set -euo pipefail

echo ""
echo "=== Container Auth Setup ==="
echo ""

# --- Git config -------------------------------------------------------------

if git config --global user.name &>/dev/null && git config --global user.email &>/dev/null; then
    echo "  SKIP: Git already configured ($(git config --global user.name) <$(git config --global user.email)>)"
else
    echo "  Git config needed."
    read -rp "  Your name: " git_name
    read -rp "  Your email: " git_email
    git config --global user.name "$git_name"
    git config --global user.email "$git_email"
    echo "  OK: Git config set"
fi

echo ""

# --- GitHub CLI auth --------------------------------------------------------

if gh auth status &>/dev/null 2>&1; then
    echo "  SKIP: GitHub CLI already authenticated"
else
    echo "  GitHub CLI needs authentication."
    echo "  This will open a URL — paste it in your browser."
    echo ""
    gh auth login --web --git-protocol https
    echo ""
    echo "  OK: GitHub CLI authenticated"
fi

echo ""

# --- Claude Code login ------------------------------------------------------

# Claude Code doesn't have an "auth status" command.
# Check for credential files as a fast proxy.
if [[ -d "$HOME/.claude" ]] && ls "$HOME/.claude/"*.json &>/dev/null 2>&1 && \
   grep -qr "oauth" "$HOME/.claude/" 2>/dev/null; then
    echo "  SKIP: Claude Code credentials found"
else
    echo "  Claude Code needs authentication."
    echo "  This will open a URL — paste it in your browser."
    echo ""
    claude login
    echo ""
    echo "  OK: Claude Code authenticated"
fi

echo ""

# --- Verification -----------------------------------------------------------

echo "=== Auth Summary ==="
echo ""

# Git
echo -n "  Git:    "
if git config --global user.name &>/dev/null; then
    echo "$(git config --global user.name) <$(git config --global user.email)>"
else
    echo "NOT CONFIGURED"
fi

# GitHub CLI
echo -n "  GitHub: "
if gh auth status &>/dev/null 2>&1; then
    echo "authenticated"
else
    echo "NOT AUTHENTICATED"
fi

# Claude Code
echo -n "  Claude: "
if grep -qr "oauth" "$HOME/.claude/" 2>/dev/null; then
    echo "credentials found"
else
    echo "NOT AUTHENTICATED (run 'claude login' inside the container)"
fi

echo ""
