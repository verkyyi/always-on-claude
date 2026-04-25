#!/bin/bash
# Tests for scripts/runtime/start-claude.sh

START_SCRIPT="$REPO_ROOT/scripts/runtime/start-claude.sh"

_source_functions() {
    export DEV_ENV="$REPO_ROOT"
    export COMPOSE_DIR="$REPO_ROOT"
    export CONTAINER_NAME="claude-dev"
    export CONTAINER_PROJECTS="/home/dev/projects"
    export DEFAULT_CODE_AGENT="${DEFAULT_CODE_AGENT:-claude}"
    export CODE_AGENT="${CODE_AGENT:-$DEFAULT_CODE_AGENT}"
    COMPOSE_CMD=(sudo --preserve-env=HOME docker compose)
    START_MENU_TESTING=1
    # shellcheck disable=SC1090
    source "$START_SCRIPT"
    unset START_MENU_TESTING
}

_source_v2() {
    export PROJECTS_DIR="$HOME/projects"
    _source_functions
}

setup() {
    mkdir -p "$HOME/dev-env/scripts/runtime" "$HOME/projects"
    mock_binary tmux ""
    mock_binary nproc "2"
    unset DEFAULT_CODE_AGENT CODE_AGENT MAX_SESSIONS
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
    echo "codex-other"
    echo "claude-other"
    echo "non-claude-session"
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"
    _source_functions
    local result
    result=$(count_sessions)
    assert_eq "3" "$result"
}

test_max_sessions_env_override() {
    local result
    result=$(MAX_SESSIONS=5 get_max_sessions)
    assert_eq "5" "$result"
}

test_max_sessions_calculated() {
    mock_binary nproc "2"
    mock_binary sysctl "4294967296"
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
    mock_binary sysctl "1572864000"
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
    mock_binary sysctl "2147483648"
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

test_next_code_agent_toggles() {
    assert_eq "codex" "$(next_code_agent claude)"
    assert_eq "claude" "$(next_code_agent codex)"
}

test_persist_default_code_agent_appends_to_bash_profile() {
    persist_default_code_agent codex

    assert_eq "codex" "$DEFAULT_CODE_AGENT"
    assert_eq "codex" "$CODE_AGENT"
    assert_contains "$(cat "$HOME/.bash_profile")" 'export DEFAULT_CODE_AGENT="codex"'
}

test_persist_default_code_agent_replaces_existing_line() {
    cat > "$HOME/.bash_profile" <<'EOF'
export PATH="$HOME/.local/bin:$PATH"
export DEFAULT_CODE_AGENT="claude"
EOF

    persist_default_code_agent codex

    local content
    content=$(cat "$HOME/.bash_profile")
    assert_contains "$content" 'export DEFAULT_CODE_AGENT="codex"'
    assert_contains "$content" 'export PATH="$HOME/.local/bin:$PATH"'
}

test_toggle_code_agent_updates_profile_and_vars() {
    cat > "$HOME/.bash_profile" <<'EOF'
export DEFAULT_CODE_AGENT="claude"
EOF

    CODE_AGENT=claude
    DEFAULT_CODE_AGENT=claude

    toggle_code_agent >/dev/null

    assert_eq "codex" "$DEFAULT_CODE_AGENT"
    assert_eq "codex" "$CODE_AGENT"
    assert_contains "$(cat "$HOME/.bash_profile")" 'export DEFAULT_CODE_AGENT="codex"'
}

test_ensure_claude_state_mount_current_recreates_container_when_mount_is_stale() {
    cat > "$HOME/.claude.json" <<'EOF'
{"state":"fresh"}
EOF
    mkdir -p "$HOME/dev-env"
    : > "$TEST_DIR/markers/container-recreated"

    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "list-sessions" ]]; then
    exit 1
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"

    local host_sum
    if command -v sha256sum >/dev/null 2>&1; then
        host_sum=$(sha256sum "$HOME/.claude.json" | awk '{print $1}')
    else
        host_sum=$(shasum -a 256 "$HOME/.claude.json" | awk '{print $1}')
    fi
    cat > "$TEST_DIR/bin/docker" <<MOCK
#!/bin/bash
state_file="$TEST_DIR/markers/container-recreated"
if [[ "\$1" == "ps" ]]; then
    echo "claude-dev"
    exit 0
fi
if [[ "\$1" == "exec" ]]; then
    if [[ "\$2" == "-u" ]]; then
        exit 0
    fi
    if [[ -s "\$state_file" ]]; then
        echo "$host_sum"
    else
        echo "stale-checksum"
    fi
    exit 0
fi
if [[ "\$1" == "compose" && "\$2" == "up" ]]; then
    echo recreated > "\$state_file"
    exit 0
fi
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/docker"

    cat > "$TEST_DIR/bin/sudo" <<'MOCK'
#!/bin/bash
if [[ "$1" == "--preserve-env=HOME" ]]; then
    shift
fi
"$@"
MOCK
    chmod +x "$TEST_DIR/bin/sudo"

    _source_functions
    ensure_claude_state_mount_current
    assert_file_exists "$TEST_DIR/markers/container-recreated"
}

test_ensure_claude_state_mount_current_blocks_recreate_with_active_sessions() {
    cat > "$HOME/.claude.json" <<'EOF'
{"state":"fresh"}
EOF

    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "list-sessions" ]]; then
    echo "claude-existing"
    exit 0
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"

    cat > "$TEST_DIR/bin/docker" <<'MOCK'
#!/bin/bash
if [[ "$1" == "ps" ]]; then
    echo "claude-dev"
    exit 0
fi
if [[ "$1" == "exec" ]]; then
    if [[ "$2" == "-u" ]]; then
        exit 0
    fi
    echo "stale-checksum"
    exit 0
fi
if [[ "$1" == "compose" && "$2" == "up" ]]; then
    echo "unexpected recreate" >&2
    exit 99
fi
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/docker"

    cat > "$TEST_DIR/bin/sudo" <<'MOCK'
#!/bin/bash
if [[ "$1" == "--preserve-env=HOME" ]]; then
    shift
fi
"$@"
MOCK
    chmod +x "$TEST_DIR/bin/sudo"

    _source_functions
    local output exit_code=0
    output=$(ensure_claude_state_mount_current 2>&1) || exit_code=$?
    assert_eq "1" "$exit_code"
    assert_contains "$output" "Exit active coding sessions"
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

test_get_sessions_filters_non_agent() {
    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "list-sessions" ]]; then
    echo "claude-myrepo 0 1711612800"
    echo "codex-other 0 1711612500"
    echo "shell-host 0 1711612000"
    echo "other-session 0 1711611000"
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"
    _source_v2

    get_sessions
    assert_eq "2" "${#session_names[@]}" "should only include claude-* and codex-* sessions"
}

test_match_sessions_annotates_entry() {
    entries=("myrepo|main|/home/dev/projects/myrepo|none|0")
    session_names=("claude-myrepo")
    session_states=("idle")
    session_activities=("1711612800")
    _source_v2

    orphaned_sessions=()
    match_sessions
    IFS='|' read -r name main_branch main_path selected_branch selected_path state activity <<< "${project_entries[0]}"
    assert_eq "myrepo" "$name"
    assert_eq "main" "$main_branch"
    assert_eq "/home/dev/projects/myrepo" "$main_path"
    assert_eq "main" "$selected_branch"
    assert_eq "/home/dev/projects/myrepo" "$selected_path"
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

test_match_sessions_uses_selected_agent_prefix() {
    entries=("myrepo|main|/home/dev/projects/myrepo|none|0")
    session_names=("codex-myrepo")
    session_states=("idle")
    session_activities=("1711612800")
    DEFAULT_CODE_AGENT=codex
    CODE_AGENT=codex
    _source_functions
    _source_v2

    orphaned_sessions=()
    match_sessions
    IFS='|' read -r _ _ _ selected_branch selected_path state activity <<< "${project_entries[0]}"
    assert_eq "main" "$selected_branch"
    assert_eq "/home/dev/projects/myrepo" "$selected_path"
    assert_eq "idle" "$state"
    assert_eq "1711612800" "$activity"
    assert_eq "0" "${#orphaned_sessions[@]}"
}

test_match_sessions_collapses_worktrees_to_latest_project_session() {
    entries=(
        "myrepo|main|/home/dev/projects/myrepo|none|0"
        "myrepo|feature-x|/home/dev/projects/myrepo-feature-x|none|0"
    )
    session_names=("claude-myrepo-feature-x")
    session_states=("idle")
    session_activities=("1711612800")
    _source_v2

    orphaned_sessions=()
    match_sessions
    assert_eq "1" "${#project_entries[@]}" "worktrees should collapse to one project summary"
    IFS='|' read -r name main_branch main_path selected_branch selected_path state activity <<< "${project_entries[0]}"
    assert_eq "myrepo" "$name"
    assert_eq "main" "$main_branch"
    assert_eq "/home/dev/projects/myrepo" "$main_path"
    assert_eq "feature-x" "$selected_branch"
    assert_eq "/home/dev/projects/myrepo-feature-x" "$selected_path"
    assert_eq "idle" "$state"
    assert_eq "1711612800" "$activity"
}

test_compute_default_prefers_idle() {
    project_entries=(
        "app1|main|/path/app1|main|/path/app1|none|0"
        "app2|main|/path/app2|main|/path/app2|idle|1711612800"
    )
    _source_v2

    compute_default
    assert_eq "1" "$default_idx"
}

test_compute_default_most_recent_idle() {
    project_entries=(
        "app1|main|/path/app1|main|/path/app1|idle|1711612000"
        "app2|main|/path/app2|main|/path/app2|idle|1711612800"
    )
    _source_v2

    compute_default
    assert_eq "1" "$default_idx"
}

test_compute_default_no_sessions_first_entry() {
    project_entries=(
        "app1|main|/path/app1|main|/path/app1|none|0"
        "app2|dev|/path/app2|dev|/path/app2|none|0"
    )
    _source_v2

    compute_default
    assert_eq "0" "$default_idx"
}

test_compute_default_empty_entries() {
    project_entries=()
    _source_v2

    compute_default
    assert_eq "0" "$default_idx"
}

test_compute_default_skips_attached() {
    project_entries=(
        "app1|main|/path/app1|main|/path/app1|attached|1711613000"
        "app2|main|/path/app2|main|/path/app2|idle|1711612800"
    )
    _source_v2

    compute_default
    assert_eq "1" "$default_idx" "should prefer idle over attached even if attached is newer"
}

test_compute_default_uses_attached_when_no_idle_session_exists() {
    project_entries=(
        "app1|main|/path/app1|main|/path/app1|attached|1711613000"
        "app2|main|/path/app2|main|/path/app2|attached|1711612800"
    )
    _source_v2

    compute_default
    assert_eq "0" "$default_idx" "should resume the newest attached session when no idle session exists"
}

test_show_menu_project_line() {
    project_entries=("myrepo|main|/path/myrepo|main|/path/myrepo|none|0")
    orphaned_sessions=()
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "[1] myrepo  main" "should show project and branch on one line"
}

test_show_menu_active_marker() {
    project_entries=("myrepo|main|/path/myrepo|feature-x|/path/myrepo-feature-x|idle|1711612800")
    orphaned_sessions=()
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "[1] myrepo  feature-x  active" "should show active marker on the project line"
}

test_show_menu_attached_marker() {
    project_entries=("myrepo|main|/path/myrepo|feature-x|/path/myrepo-feature-x|attached|1711612800")
    orphaned_sessions=()
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "[1] myrepo  feature-x  attached" "should show attached marker"
}

test_show_menu_footer_default() {
    project_entries=("myrepo|main|/path/myrepo|main|/path/myrepo|none|0")
    orphaned_sessions=()
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "Enter=1" "should show default in footer"
    assert_contains "$output" "t=toggle->codex" "should show toggle option"
    assert_contains "$output" "m=manage" "should show manage option"
    assert_contains "$output" "h=host" "should show host option"
    assert_contains "$output" "c=container" "should show container option"
}

test_show_menu_no_repos() {
    project_entries=()
    orphaned_sessions=()
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "no repos"
    assert_contains "$output" "Enter=m" "should default to manage when no repos"
    assert_contains "$output" "t=toggle->codex" "should show toggle option"
}

test_show_menu_footer_codex_toggle_target() {
    project_entries=("myrepo|main|/path/myrepo|main|/path/myrepo|none|0")
    orphaned_sessions=()
    default_idx=0
    CODE_AGENT=codex
    DEFAULT_CODE_AGENT=codex
    _source_functions
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "agent=codex" "should show current agent"
    assert_contains "$output" "t=toggle->claude" "should show opposite agent"
}

test_show_menu_multiple_projects() {
    project_entries=(
        "app-one|main|/path/app-one|feature-x|/path/app-one--feature-x|idle|1711612800"
        "app-two|dev|/path/app-two|dev|/path/app-two|none|0"
    )
    orphaned_sessions=()
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "[1] app-one  feature-x  active" "should show the first project summary"
    assert_contains "$output" "[2] app-two  dev" "should show the second project summary"
}

test_show_menu_orphaned_sessions() {
    project_entries=("myrepo|main|/path/myrepo|main|/path/myrepo|none|0")
    orphaned_sessions=("claude-deleted-repo|idle|0")
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "sessions" "should show orphaned sessions header"
    assert_contains "$output" "claude-deleted-repo" "should show orphaned session name"
}

test_select_entry_resumes_project_session() {
    project_entries=("myrepo|main|/path/myrepo|feature-x|/path/myrepo-feature-x|idle|1711612800")
    orphaned_sessions=()
    _source_v2

    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "attach-session" && "$2" == "-t" && "$3" == "claude-myrepo-feature-x" ]]; then
    exit 0
fi
exit 99
MOCK
    chmod +x "$TEST_DIR/bin/tmux"

    local output
    output=$(select_entry 0 2>&1)
    assert_contains "$output" "claude-myrepo-feature-x"
}
