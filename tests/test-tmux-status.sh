#!/bin/bash
# Tests for scripts/runtime/tmux-status.sh

STATUS_SCRIPT="$REPO_ROOT/scripts/runtime/tmux-status.sh"

test_format_zero_sessions() {
    mock_binary tmux ""
    mock_binary nproc "2"

    local output
    output=$(MAX_SESSIONS=3 bash "$STATUS_SCRIPT")
    assert_contains "$output" "0/3"
}

test_format_multiple_sessions() {
    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "list-sessions" ]]; then
    echo "claude-repo1"
    echo "claude-repo2"
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"

    local output
    output=$(MAX_SESSIONS=4 bash "$STATUS_SCRIPT")
    assert_contains "$output" "2/4"
}

test_respects_max_sessions_env() {
    mock_binary tmux ""
    local output
    output=$(MAX_SESSIONS=7 bash "$STATUS_SCRIPT")
    assert_contains "$output" "0/7"
}
