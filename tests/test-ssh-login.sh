#!/bin/bash
# Tests for scripts/runtime/ssh-login.sh

LOGIN_SCRIPT="$REPO_ROOT/scripts/runtime/ssh-login.sh"

setup() {
    mkdir -p "$HOME/dev-env/scripts/runtime"
}

test_skips_non_interactive() {
    _EXIT_CODE=0
    _OUTPUT=$(
        env HOME="$HOME" SSH_CONNECTION="1.2.3.4 1234 5.6.7.8 22" \
            bash -c "source '$LOGIN_SCRIPT'" 2>&1
    ) || _EXIT_CODE=$?
    assert_file_not_exists "$TEST_DIR/markers/start-claude"
    assert_file_not_exists "$TEST_DIR/markers/onboarding"
}

test_skips_in_tmux() {
    _EXIT_CODE=0
    _OUTPUT=$(
        env HOME="$HOME" SSH_CONNECTION="1.2.3.4 1234 5.6.7.8 22" TMUX="/tmp/tmux-1000/default,1234,0" \
            bash -i -c "source '$LOGIN_SCRIPT'" 2>&1
    ) || _EXIT_CODE=$?
    assert_file_not_exists "$TEST_DIR/markers/start-claude"
    assert_file_not_exists "$TEST_DIR/markers/onboarding"
}

test_skips_no_claude() {
    _EXIT_CODE=0
    _OUTPUT=$(
        env HOME="$HOME" SSH_CONNECTION="1.2.3.4 1234 5.6.7.8 22" NO_CLAUDE=1 \
            bash -i -c "source '$LOGIN_SCRIPT'" 2>&1
    ) || _EXIT_CODE=$?
    assert_file_not_exists "$TEST_DIR/markers/start-claude"
}

test_skips_no_ssh() {
    _EXIT_CODE=0
    _OUTPUT=$(
        env -u SSH_CONNECTION HOME="$HOME" \
            bash -i -c "source '$LOGIN_SCRIPT'" 2>&1
    ) || _EXIT_CODE=$?
    assert_file_not_exists "$TEST_DIR/markers/start-claude"
}

test_shows_update_pending() {
    mkdir -p "$HOME/dev-env/scripts/runtime"
    touch "$HOME/.workspace-initialized"
    echo "updated=2026-03-25" > "$HOME/.update-pending"
    cat > "$HOME/dev-env/scripts/runtime/start-claude.sh" <<'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$HOME/dev-env/scripts/runtime/start-claude.sh"

    _EXIT_CODE=0
    _OUTPUT=$(
        env HOME="$HOME" SSH_CONNECTION="1.2.3.4 1234 5.6.7.8 22" \
            bash -i -c "source '$LOGIN_SCRIPT'" 2>&1
    ) || _EXIT_CODE=$?
    assert_contains "$_OUTPUT" "Updates available"
}

test_execs_onboarding_when_not_initialized() {
    mkdir -p "$HOME/dev-env/scripts/runtime"
    cat > "$HOME/dev-env/scripts/runtime/onboarding.sh" <<MOCK
#!/bin/bash
echo "ONBOARDING_CALLED" > "$TEST_DIR/markers/onboarding"
MOCK
    chmod +x "$HOME/dev-env/scripts/runtime/onboarding.sh"

    _EXIT_CODE=0
    _OUTPUT=$(
        env HOME="$HOME" SSH_CONNECTION="1.2.3.4 1234 5.6.7.8 22" \
            bash -i -c "source '$LOGIN_SCRIPT'" 2>&1
    ) || _EXIT_CODE=$?
    assert_file_exists "$TEST_DIR/markers/onboarding"
}

test_execs_start_claude_when_initialized() {
    mkdir -p "$HOME/dev-env/scripts/runtime"
    touch "$HOME/.workspace-initialized"
    cat > "$HOME/dev-env/scripts/runtime/start-claude.sh" <<MOCK
#!/bin/bash
echo "START_CLAUDE_CALLED" > "$TEST_DIR/markers/start-claude"
MOCK
    chmod +x "$HOME/dev-env/scripts/runtime/start-claude.sh"

    _EXIT_CODE=0
    _OUTPUT=$(
        env HOME="$HOME" SSH_CONNECTION="1.2.3.4 1234 5.6.7.8 22" \
            bash -i -c "source '$LOGIN_SCRIPT'" 2>&1
    ) || _EXIT_CODE=$?
    assert_file_exists "$TEST_DIR/markers/start-claude"
}
