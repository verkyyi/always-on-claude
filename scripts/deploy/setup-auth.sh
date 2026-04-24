#!/bin/bash
# setup-auth.sh — In-container auth helper.
# Run via: docker compose exec dev bash ~/dev-env/scripts/deploy/setup-auth.sh
#
# Handles git config, GitHub CLI auth, and the preferred coding assistant login.
# Idempotent — skips steps that are already done.

set -euo pipefail

CONFIG_ROOT="${DEV_ENV:-$HOME/dev-env}"
if [[ -f "$CONFIG_ROOT/scripts/deploy/load-config.sh" ]]; then
    # shellcheck disable=SC1091
    source "$CONFIG_ROOT/scripts/deploy/load-config.sh"
fi

normalize_code_agent() {
    case "${1:-}" in
        codex) echo "codex" ;;
        claude|"") echo "claude" ;;
        *) echo "claude" ;;
    esac
}

code_agent_label() {
    case "$(normalize_code_agent "$1")" in
        codex) echo "Codex" ;;
        *) echo "Claude Code" ;;
    esac
}

code_agent_login_command() {
    case "$(normalize_code_agent "$1")" in
        codex) echo "codex --login" ;;
        *) echo "claude login" ;;
    esac
}

code_agent_auth_hint() {
    case "$(normalize_code_agent "$1")" in
        codex) echo "Use the Codex login flow for ChatGPT subscription access; on a remote SSH host, follow the device-code step Codex shows in your browser, or use OPENAI_API_KEY." ;;
        *) echo "This will open a browser flow, or you can use ANTHROPIC_API_KEY." ;;
    esac
}

code_agent_reauth_hint() {
    local login_command
    login_command="$(code_agent_login_command "$1")"

    case "$(normalize_code_agent "$1")" in
        codex) echo "run '$login_command' or set OPENAI_API_KEY inside the container" ;;
        *) echo "run '$login_command' or set ANTHROPIC_API_KEY inside the container" ;;
    esac
}

claude_authenticated() {
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && return 0
    [[ -d "$HOME/.claude" ]] \
        && ls "$HOME/.claude/"*.json &>/dev/null 2>&1 \
        && grep -qr --exclude-dir=debug "oauth" "$HOME/.claude/" 2>/dev/null
}

codex_authenticated() {
    [[ -n "${OPENAI_API_KEY:-}" ]] && return 0
    command -v codex &>/dev/null && codex login status &>/dev/null
}

run_code_agent_login() {
    case "$(normalize_code_agent "$1")" in
        codex) codex --login ;;
        *) claude login ;;
    esac
}

preferred_agent=$(normalize_code_agent "${DEFAULT_CODE_AGENT:-claude}")

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

# --- Preferred coding assistant login --------------------------------------

echo "  Preferred assistant: $(code_agent_label "$preferred_agent")"
echo ""

if [[ "$preferred_agent" == "codex" ]]; then
    if codex_authenticated; then
        echo "  SKIP: Codex already authenticated"
    elif ! command -v codex &>/dev/null; then
        echo "  WARN: Codex is not installed in this container."
    else
        echo "  Codex needs authentication."
        echo "  $(code_agent_auth_hint "$preferred_agent")"
        echo ""
        run_code_agent_login "$preferred_agent"
        echo ""
        echo "  OK: Codex authenticated"
    fi
else
    if claude_authenticated; then
        echo "  SKIP: Claude Code credentials found"
    elif ! command -v claude &>/dev/null; then
        echo "  WARN: Claude Code is not installed in this container."
    else
        echo "  Claude Code needs authentication."
        echo "  $(code_agent_auth_hint "$preferred_agent")"
        echo ""
        run_code_agent_login "$preferred_agent"
        echo ""
        echo "  OK: Claude Code authenticated"
    fi
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
if claude_authenticated; then
    echo "credentials found"
else
    echo "NOT AUTHENTICATED ($(code_agent_reauth_hint claude))"
fi

# Codex
echo -n "  Codex:  "
if codex_authenticated; then
    echo "authenticated"
else
    echo "NOT AUTHENTICATED ($(code_agent_reauth_hint codex))"
fi

echo ""
