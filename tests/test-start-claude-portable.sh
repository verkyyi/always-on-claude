#!/bin/bash
# Tests for scripts/portable/start-claude-portable.sh

PORTABLE_SCRIPT="$REPO_ROOT/scripts/portable/start-claude-portable.sh"

_source_functions() {
    eval "$(sed -n '/^all_code_agent_session_pattern()/,/^}/p' "$PORTABLE_SCRIPT")"
    eval "$(sed -n '/^count_sessions()/,/^}/p' "$PORTABLE_SCRIPT")"
    eval "$(sed -n '/^get_max_sessions()/,/^}/p' "$PORTABLE_SCRIPT")"
    eval "$(sed -n '/^tmux_detach_hint()/,/^}/p' "$PORTABLE_SCRIPT")"
    eval "$(sed -n '/^check_session_limit()/,/^}/p' "$PORTABLE_SCRIPT")"
}

setup() {
    _source_functions
    unset MAX_SESSIONS
}

test_max_sessions_env_override() {
    MAX_SESSIONS=2
    assert_eq "2" "$(get_max_sessions)"
}

test_count_sessions_counts_only_code_agents() {
    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "list-sessions" ]]; then
    echo "claude-app"
    echo "codex-api"
    echo "shell-local"
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"

    assert_eq "2" "$(count_sessions)"
}

test_check_session_limit_allows_reattach() {
    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "has-session" ]]; then
    exit 0
fi
if [[ "$1" == "list-sessions" ]]; then
    echo "claude-existing"
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"

    MAX_SESSIONS=1
    check_session_limit "claude-existing"
}

test_check_session_limit_blocks_new_session_at_limit() {
    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "has-session" ]]; then
    exit 1
fi
if [[ "$1" == "list-sessions" ]]; then
    echo "claude-existing"
fi
if [[ "$1" == "show-option" ]]; then
    echo "C-b"
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"

    MAX_SESSIONS=1
    local output exit_code=0
    output=$(check_session_limit "claude-new" 2>&1) || exit_code=$?

    assert_eq "1" "$exit_code"
    assert_contains "$output" "Session limit reached (1/1)"
    assert_contains "$output" "Ctrl-b d"
}
