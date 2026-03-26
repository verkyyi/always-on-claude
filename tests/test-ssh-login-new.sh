#!/bin/bash
# Tests for ssh-login.sh features: mobile detection, DEV_ENV config

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

