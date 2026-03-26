#!/bin/bash
# Tests for new ssh-login.sh features: mobile detection, version check notification, DEV_ENV config

LOGIN_SCRIPT="$REPO_ROOT/scripts/runtime/ssh-login.sh"

setup() {
    mkdir -p "$HOME/dev-env/scripts/runtime"
    touch "$HOME/.workspace-initialized"
    # Create a mock start-claude.sh that just exits
    cat > "$HOME/dev-env/scripts/runtime/start-claude.sh" <<'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$HOME/dev-env/scripts/runtime/start-claude.sh"
}

test_shows_version_update_notification() {
    cat > "$HOME/.claude-version-check" <<'EOF'
status=update-available
installed=2.1.79
latest=2.1.80
checked=2026-03-25T10:00:00+00:00
EOF

    _EXIT_CODE=0
    _OUTPUT=$(
        env HOME="$HOME" SSH_CONNECTION="1.2.3.4 1234 5.6.7.8 22" \
            bash -i -c "source '$LOGIN_SCRIPT'" 2>&1
    ) || _EXIT_CODE=$?
    assert_contains "$_OUTPUT" "Claude Code update: 2.1.79 -> 2.1.80"
    assert_contains "$_OUTPUT" "/update-claude-code"
}

test_no_version_notification_when_current() {
    cat > "$HOME/.claude-version-check" <<'EOF'
status=current
installed=2.1.80
latest=2.1.80
checked=2026-03-25T10:00:00+00:00
EOF

    _EXIT_CODE=0
    _OUTPUT=$(
        env HOME="$HOME" SSH_CONNECTION="1.2.3.4 1234 5.6.7.8 22" \
            bash -i -c "source '$LOGIN_SCRIPT'" 2>&1
    ) || _EXIT_CODE=$?
    # Should NOT contain update notification
    if [[ "$_OUTPUT" == *"Claude Code update:"* ]]; then
        _fail "should not show update notification when current"
    fi
}

test_no_version_notification_when_no_file() {
    # No .claude-version-check file
    _EXIT_CODE=0
    _OUTPUT=$(
        env HOME="$HOME" SSH_CONNECTION="1.2.3.4 1234 5.6.7.8 22" \
            bash -i -c "source '$LOGIN_SCRIPT'" 2>&1
    ) || _EXIT_CODE=$?
    if [[ "$_OUTPUT" == *"Claude Code update:"* ]]; then
        _fail "should not show update notification when no version file"
    fi
}

test_uses_custom_dev_env_path() {
    # Set up a custom DEV_ENV location
    local custom="$HOME/custom-env"
    mkdir -p "$custom/scripts/runtime"
    cat > "$custom/scripts/runtime/start-claude.sh" <<MOCK
#!/bin/bash
echo "CUSTOM_START" > "$TEST_DIR/markers/custom-start"
MOCK
    chmod +x "$custom/scripts/runtime/start-claude.sh"

    _EXIT_CODE=0
    _OUTPUT=$(
        env HOME="$HOME" SSH_CONNECTION="1.2.3.4 1234 5.6.7.8 22" DEV_ENV="$custom" \
            bash -i -c "source '$LOGIN_SCRIPT'" 2>&1
    ) || _EXIT_CODE=$?
    assert_file_exists "$TEST_DIR/markers/custom-start"
}

test_both_update_and_version_notifications() {
    echo "updated=2026-03-25" > "$HOME/.update-pending"
    cat > "$HOME/.claude-version-check" <<'EOF'
status=update-available
installed=2.1.79
latest=2.1.80
EOF

    _EXIT_CODE=0
    _OUTPUT=$(
        env HOME="$HOME" SSH_CONNECTION="1.2.3.4 1234 5.6.7.8 22" \
            bash -i -c "source '$LOGIN_SCRIPT'" 2>&1
    ) || _EXIT_CODE=$?
    assert_contains "$_OUTPUT" "Updates available"
    assert_contains "$_OUTPUT" "Claude Code update: 2.1.79 -> 2.1.80"
}
