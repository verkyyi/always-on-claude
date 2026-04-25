#!/bin/bash
# Tests for scripts/portable/start-claude-portable.sh

PORTABLE_SCRIPT="$REPO_ROOT/scripts/portable/start-claude-portable.sh"

_source_functions() {
    export DEV_ENV="$REPO_ROOT"
    export DEFAULT_CODE_AGENT="${DEFAULT_CODE_AGENT:-claude}"
    export CODE_AGENT="${CODE_AGENT:-$DEFAULT_CODE_AGENT}"
    START_MENU_TESTING=1
    # shellcheck disable=SC1090
    source "$PORTABLE_SCRIPT"
    unset START_MENU_TESTING
}

_source_v2() {
    export PROJECTS_DIR="$HOME/projects"
    _source_functions
}

setup() {
    mkdir -p "$HOME/projects"
    mock_binary tmux ""
    mock_binary nproc "2"
    unset DEFAULT_CODE_AGENT CODE_AGENT MAX_SESSIONS
    _source_functions
    _source_v2
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

test_get_sessions_filters_non_agent() {
    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "list-sessions" ]]; then
    echo "claude-myrepo 0 1711612800"
    echo "codex-other 0 1711612500"
    echo "shell-local 0 1711612000"
    echo "other-session 0 1711611000"
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"
    _source_v2

    get_sessions
    assert_eq "3" "${#session_names[@]}"
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
    assert_eq "1" "${#project_entries[@]}"
    IFS='|' read -r name main_branch main_path selected_branch selected_path state activity <<< "${project_entries[0]}"
    assert_eq "myrepo" "$name"
    assert_eq "main" "$main_branch"
    assert_eq "/home/dev/projects/myrepo" "$main_path"
    assert_eq "feature-x" "$selected_branch"
    assert_eq "/home/dev/projects/myrepo-feature-x" "$selected_path"
    assert_eq "idle" "$state"
    assert_eq "1711612800" "$activity"
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

test_compute_default_uses_attached_when_no_idle_session_exists() {
    project_entries=(
        "app1|main|/path/app1|main|/path/app1|attached|1711613000"
        "app2|main|/path/app2|main|/path/app2|attached|1711612800"
    )
    _source_v2

    compute_default
    assert_eq "0" "$default_idx"
}

test_show_menu_project_line() {
    project_entries=("myrepo|main|/path/myrepo|main|/path/myrepo|none|0")
    orphaned_sessions=()
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "[1] myrepo  main"
}

test_show_menu_active_marker() {
    project_entries=("myrepo|main|/path/myrepo|feature-x|/path/myrepo-feature-x|idle|1711612800")
    orphaned_sessions=()
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "[1] myrepo  feature-x  active"
}

test_show_menu_footer() {
    project_entries=("myrepo|main|/path/myrepo|main|/path/myrepo|none|0")
    orphaned_sessions=()
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "Enter=1"
    assert_contains "$output" "m=manage"
    assert_contains "$output" "h=shell"
}

test_show_menu_no_repos() {
    project_entries=()
    orphaned_sessions=()
    default_idx=0
    _source_v2

    local output
    output=$(show_menu)
    assert_contains "$output" "no repos"
    assert_contains "$output" "Enter=m"
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

test_select_entry_launches_main_path_when_no_session_exists() {
    project_entries=("myrepo|main|/path/myrepo|feature-x|/path/myrepo-feature-x|none|0")
    orphaned_sessions=()
    _source_v2

    launch() {
        echo "launch:$1"
    }

    local output
    output=$(select_entry 0 2>&1)
    assert_contains "$output" "launch:/path/myrepo"
}
