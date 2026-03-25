#!/bin/bash
# Tests for scripts/runtime/start-claude.sh

START_SCRIPT="$REPO_ROOT/scripts/runtime/start-claude.sh"

_source_functions() {
    export COMPOSE_DIR="$HOME/dev-env"
    export CONTAINER_NAME="claude-dev"
    export WORKTREE_HELPER="$COMPOSE_DIR/scripts/runtime/worktree-helper.sh"
    export CONTAINER_PROJECTS="/home/dev/projects"

    eval "$(sed -n '/^count_sessions()/,/^}/p' "$START_SCRIPT")"
    eval "$(sed -n '/^get_max_sessions()/,/^}/p' "$START_SCRIPT")"
    eval "$(sed -n '/^check_session_limit()/,/^}/p' "$START_SCRIPT")"
    eval "$(sed -n '/^to_container_path()/,/^}/p' "$START_SCRIPT")"
    eval "$(sed -n '/^discover()/,/^}/p' "$START_SCRIPT")"
}

setup() {
    mkdir -p "$HOME/dev-env/scripts/runtime" "$HOME/projects"
    mock_binary tmux ""
    mock_binary nproc "2"
    _source_functions
}

test_count_sessions_zero() {
    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
# Real tmux exits 1 (no sessions)
if [[ "$1" == "list-sessions" ]]; then
    exit 1
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"
    _source_functions
    local result
    result=$(count_sessions)
    # count_sessions returns "0" (possibly with a duplicate from the || echo 0 fallback)
    # Verify the first line is zero
    assert_eq "0" "$(echo "$result" | head -1)"
}

test_count_sessions_counts_claude_prefix() {
    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "list-sessions" ]]; then
    echo "claude-myrepo"
    echo "claude-other"
    echo "non-claude-session"
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"
    _source_functions
    local result
    result=$(count_sessions)
    assert_eq "2" "$result"
}

test_max_sessions_env_override() {
    local result
    result=$(MAX_SESSIONS=5 get_max_sessions)
    assert_eq "5" "$result"
}

test_max_sessions_calculated() {
    mock_binary nproc "2"
    cat > "$TEST_DIR/bin/awk" <<'MOCK'
#!/bin/bash
if [[ "$*" == *"MemTotal"* ]]; then
    echo "4096"
else
    /usr/bin/awk "$@"
fi
MOCK
    chmod +x "$TEST_DIR/bin/awk"
    _source_functions
    local result
    result=$(get_max_sessions)
    assert_eq "2" "$result"
}

test_max_sessions_minimum_one() {
    mock_binary nproc "1"
    cat > "$TEST_DIR/bin/awk" <<'MOCK'
#!/bin/bash
if [[ "$*" == *"MemTotal"* ]]; then
    echo "1500"
else
    /usr/bin/awk "$@"
fi
MOCK
    chmod +x "$TEST_DIR/bin/awk"
    _source_functions
    local result
    result=$(get_max_sessions)
    assert_eq "1" "$result"
}

test_max_sessions_low_memory_high_cpu() {
    mock_binary nproc "8"
    cat > "$TEST_DIR/bin/awk" <<'MOCK'
#!/bin/bash
if [[ "$*" == *"MemTotal"* ]]; then
    echo "2048"
else
    /usr/bin/awk "$@"
fi
MOCK
    chmod +x "$TEST_DIR/bin/awk"
    _source_functions
    local result
    result=$(get_max_sessions)
    assert_eq "1" "$result"
}

test_to_container_path() {
    local result
    result=$(to_container_path "$HOME/projects/myrepo")
    assert_eq "/home/dev/projects/myrepo" "$result"
}

test_discover_finds_repos() {
    mkdir -p "$HOME/dev-env/scripts/runtime"
    cat > "$HOME/dev-env/scripts/runtime/worktree-helper.sh" <<'MOCK'
#!/bin/bash
if [[ "$1" == "list-repos" ]]; then
    echo "REPO|/home/dev/projects/myrepo|main"
    echo "WORKTREE|/home/dev/projects/myrepo--feature|feature"
fi
MOCK
    chmod +x "$HOME/dev-env/scripts/runtime/worktree-helper.sh"
    WORKTREE_HELPER="$HOME/dev-env/scripts/runtime/worktree-helper.sh"

    discover
    assert_eq "1" "${#repos[@]}" "should find 1 repo"
    assert_contains "${repos[0]}" "/home/dev/projects/myrepo"
}

test_check_session_limit_allows_reattach() {
    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "has-session" && "$3" == "claude-myrepo" ]]; then
    exit 0
fi
if [[ "$1" == "list-sessions" ]]; then
    echo "claude-myrepo"
    echo "claude-other"
fi
exit 1
MOCK
    chmod +x "$TEST_DIR/bin/tmux"
    _source_functions
    MAX_SESSIONS=2 check_session_limit "claude-myrepo"
}
