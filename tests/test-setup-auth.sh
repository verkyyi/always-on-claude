#!/bin/bash
# Tests for scripts/deploy/setup-auth.sh helper functions

SETUP_AUTH_SCRIPT="$REPO_ROOT/scripts/deploy/setup-auth.sh"

_source_helpers() {
    eval "$(sed -n '/^normalize_code_agent()/,/^}/p' "$SETUP_AUTH_SCRIPT")"
    eval "$(sed -n '/^code_agent_label()/,/^}/p' "$SETUP_AUTH_SCRIPT")"
    eval "$(sed -n '/^code_agent_login_command()/,/^}/p' "$SETUP_AUTH_SCRIPT")"
    eval "$(sed -n '/^code_agent_auth_hint()/,/^}/p' "$SETUP_AUTH_SCRIPT")"
    eval "$(sed -n '/^code_agent_reauth_hint()/,/^}/p' "$SETUP_AUTH_SCRIPT")"
}

setup() {
    _source_helpers
}

test_code_agent_label_codex() {
    assert_eq "Codex" "$(code_agent_label codex)"
}

test_code_agent_label_claude_default() {
    assert_eq "Claude Code" "$(code_agent_label bogus)"
}

test_code_agent_login_command_codex_uses_browser_login_flag() {
    assert_eq "codex --login" "$(code_agent_login_command codex)"
}

test_code_agent_login_command_claude() {
    assert_eq "claude login" "$(code_agent_login_command claude)"
}

test_code_agent_auth_hint_mentions_chatgpt_for_codex() {
    assert_contains "$(code_agent_auth_hint codex)" "device-code"
}

test_code_agent_reauth_hint_mentions_codex_login_flag() {
    assert_contains "$(code_agent_reauth_hint codex)" "codex --login"
}
