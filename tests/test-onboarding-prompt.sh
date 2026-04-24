#!/bin/bash
# Tests for scripts/runtime/onboarding-prompt.txt

PROMPT_FILE="$REPO_ROOT/scripts/runtime/onboarding-prompt.txt"

test_prompt_mentions_codex_subscription_login() {
    local prompt
    prompt="$(cat "$PROMPT_FILE")"
    assert_contains "$prompt" "codex --login"
    assert_contains "$prompt" "device-code"
}

test_prompt_verifies_container_auth_state() {
    local prompt
    prompt="$(cat "$PROMPT_FILE")"
    assert_contains "$prompt" 'docker exec "$CONTAINER_NAME"'
    assert_contains "$prompt" "codex login status"
}
