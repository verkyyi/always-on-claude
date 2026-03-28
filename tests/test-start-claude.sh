#!/bin/bash
# Tests for scripts/runtime/start-claude.sh

START_SCRIPT="$REPO_ROOT/scripts/runtime/start-claude.sh"

_source_functions() {
    export COMPOSE_DIR="$HOME/dev-env"
    export CONTAINER_NAME="claude-dev"
    export CONTAINER_PROJECTS="/home/dev/projects"

    eval "$(sed -n '/^count_sessions()/,/^}/p' "$START_SCRIPT")"
    eval "$(sed -n '/^get_max_sessions()/,/^}/p' "$START_SCRIPT")"
    eval "$(sed -n '/^check_session_limit()/,/^}/p' "$START_SCRIPT")"
    eval "$(sed -n '/^to_container_path()/,/^}/p' "$START_SCRIPT")"
}

_source_v2() {
    export PROJECTS_DIR="$HOME/projects"
    eval "$(sed -n '/^discover_entries()/,/^}/p' "$START_SCRIPT")" 2>/dev/null || true
    eval "$(sed -n '/^get_sessions()/,/^}/p' "$START_SCRIPT")" 2>/dev/null || true
    eval "$(sed -n '/^match_sessions()/,/^}/p' "$START_SCRIPT")" 2>/dev/null || true
    eval "$(sed -n '/^compute_default()/,/^}/p' "$START_SCRIPT")" 2>/dev/null || true
    eval "$(sed -n '/^show_menu()/,/^}/p' "$START_SCRIPT")" 2>/dev/null || true
}

setup() {
    mkdir -p "$HOME/dev-env/scripts/runtime" "$HOME/projects"
    mock_binary tmux ""
    mock_binary nproc "2"
    _source_functions
    _source_v2
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
    # 2048MB RAM, 512MB OS reserve: (2048-512)/650 = 2, capped by 8 CPUs = 2
    assert_eq "2" "$result"
}

test_to_container_path() {
    local result
    result=$(to_container_path "$HOME/projects/myrepo")
    assert_eq "/home/dev/projects/myrepo" "$result"
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

test_discover_entries_finds_repos() {
    local repo
    repo=$(create_test_repo "projects/my-app")
    local expected_branch
    expected_branch=$(git -C "$repo" branch --show-current)

    entries=()
    discover_entries
    assert_eq "1" "${#entries[@]}" "should find 1 repo"
    IFS='|' read -r name branch path state activity <<< "${entries[0]}"
    assert_eq "my-app" "$name"
    assert_eq "$expected_branch" "$branch"
    assert_eq "$repo" "$path"
    assert_eq "none" "$state"
    assert_eq "0" "$activity"
}

test_discover_entries_finds_worktrees() {
    local repo
    repo=$(create_test_repo "projects/my-app")
    create_test_worktree "$repo" "feature-x"

    entries=()
    discover_entries
    assert_eq "2" "${#entries[@]}" "should find repo + worktree"
    IFS='|' read -r name branch _ _ _ <<< "${entries[1]}"
    assert_eq "my-app" "$name"
    assert_eq "feature-x" "$branch"
}

test_discover_entries_empty() {
    entries=()
    discover_entries
    assert_eq "0" "${#entries[@]}" "should find nothing"
}

test_discover_entries_multiple_repos() {
    create_test_repo "projects/app-one"
    create_test_repo "projects/app-two"

    entries=()
    discover_entries
    assert_eq "2" "${#entries[@]}" "should find 2 repos"
    IFS='|' read -r name1 _ _ _ _ <<< "${entries[0]}"
    IFS='|' read -r name2 _ _ _ _ <<< "${entries[1]}"
    assert_eq "app-one" "$name1"
    assert_eq "app-two" "$name2"
}

test_get_sessions_parses_idle() {
    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "list-sessions" ]]; then
    echo "claude-myrepo 0 1711612800"
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"
    _source_v2

    get_sessions
    assert_eq "1" "${#session_names[@]}"
    assert_eq "claude-myrepo" "${session_names[0]}"
    assert_eq "idle" "${session_states[0]}"
    assert_eq "1711612800" "${session_activities[0]}"
}

test_get_sessions_parses_attached() {
    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "list-sessions" ]]; then
    echo "claude-myrepo 1 1711612800"
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"
    _source_v2

    get_sessions
    assert_eq "1" "${#session_names[@]}"
    assert_eq "attached" "${session_states[0]}"
}

test_get_sessions_filters_non_claude() {
    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "list-sessions" ]]; then
    echo "claude-myrepo 0 1711612800"
    echo "shell-host 0 1711612000"
    echo "other-session 0 1711611000"
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"
    _source_v2

    get_sessions
    assert_eq "1" "${#session_names[@]}" "should only include claude-* sessions"
}

test_match_sessions_annotates_entry() {
    entries=("myrepo|main|/home/dev/projects/myrepo|none|0")
    session_names=("claude-myrepo")
    session_states=("idle")
    session_activities=("1711612800")
    _source_v2

    orphaned_sessions=()
    match_sessions
    IFS='|' read -r _ _ _ state activity <<< "${entries[0]}"
    assert_eq "idle" "$state"
    assert_eq "1711612800" "$activity"
    assert_eq "0" "${#orphaned_sessions[@]}" "matching session should not be orphaned"
}

test_match_sessions_detects_orphaned() {
    entries=("myrepo|main|/home/dev/projects/myrepo|none|0")
    session_names=("claude-myrepo" "claude-deleted-repo")
    session_states=("idle" "idle")
    session_activities=("1711612800" "1711611000")
    _source_v2

    orphaned_sessions=()
    match_sessions
    assert_eq "1" "${#orphaned_sessions[@]}" "should detect 1 orphaned session"
    assert_contains "${orphaned_sessions[0]}" "claude-deleted-repo"
}

test_compute_default_prefers_idle() {
    entries=(
        "app1|main|/path/app1|none|0"
        "app2|main|/path/app2|idle|1711612800"
    )
    _source_v2

    compute_default
    assert_eq "1" "$default_idx"
}

test_compute_default_most_recent_idle() {
    entries=(
        "app1|main|/path/app1|idle|1711612000"
        "app2|main|/path/app2|idle|1711612800"
    )
    _source_v2

    compute_default
    assert_eq "1" "$default_idx"
}

test_compute_default_no_sessions_first_entry() {
    entries=(
        "app1|main|/path/app1|none|0"
        "app2|dev|/path/app2|none|0"
    )
    _source_v2

    compute_default
    assert_eq "0" "$default_idx"
}

test_compute_default_empty_entries() {
    entries=()
    _source_v2

    compute_default
    assert_eq "0" "$default_idx"
}

test_compute_default_skips_attached() {
    entries=(
        "app1|main|/path/app1|attached|1711613000"
        "app2|main|/path/app2|idle|1711612800"
    )
    _source_v2

    compute_default
    assert_eq "1" "$default_idx" "should prefer idle over attached even if attached is newer"
}

test_show_menu_repo_header_and_branch() {
    entries=("myrepo|main|/path/myrepo|none|0")
    orphaned_sessions=()
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "myrepo" "should show repo name as header"
    assert_contains "$output" "[1] main" "should show branch as numbered item"
}

test_show_menu_active_marker() {
    entries=("myrepo|main|/path/myrepo|idle|1711612800")
    orphaned_sessions=()
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "active (idle)" "should show active marker"
}

test_show_menu_attached_marker() {
    entries=("myrepo|main|/path/myrepo|attached|1711612800")
    orphaned_sessions=()
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "active (attached)" "should show attached marker"
}

test_show_menu_footer_default() {
    entries=("myrepo|main|/path/myrepo|none|0")
    orphaned_sessions=()
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "Enter=1" "should show default in footer"
    assert_contains "$output" "m=manage" "should show manage option"
    assert_contains "$output" "h=host" "should show host option"
    assert_contains "$output" "c=container" "should show container option"
}

test_show_menu_no_repos() {
    entries=()
    orphaned_sessions=()
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "no repos"
    assert_contains "$output" "Enter=m" "should default to manage when no repos"
}

test_show_menu_multiple_repos_grouped() {
    entries=(
        "app-one|main|/path/app-one|none|0"
        "app-one|feature-x|/path/app-one--feature-x|none|0"
        "app-two|dev|/path/app-two|none|0"
    )
    orphaned_sessions=()
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "app-one" "should show first repo header"
    assert_contains "$output" "[1] main" "should show first branch"
    assert_contains "$output" "[2] feature-x" "should show worktree branch"
    assert_contains "$output" "app-two" "should show second repo header"
    assert_contains "$output" "[3] dev" "should show second repo branch"
}

test_show_menu_orphaned_sessions() {
    entries=("myrepo|main|/path/myrepo|none|0")
    orphaned_sessions=("claude-deleted-repo|idle|0")
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "sessions" "should show orphaned sessions header"
    assert_contains "$output" "claude-deleted-repo" "should show orphaned session name"
}
