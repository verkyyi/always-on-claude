#!/bin/bash
# Tests for scripts/runtime/start-claude.sh

START_SCRIPT="$REPO_ROOT/scripts/runtime/start-claude.sh"

_source_functions() {
    export DEV_ENV="$REPO_ROOT"
    export COMPOSE_DIR="$REPO_ROOT"
    export CONTAINER_NAME="claude-dev"
    export CONTAINER_PROJECTS="/home/dev/projects"
    export PROJECTS_DIR="$HOME/projects"
    export DEFAULT_CODE_AGENT="${DEFAULT_CODE_AGENT:-claude}"
    export CODE_AGENT="${CODE_AGENT:-$DEFAULT_CODE_AGENT}"
    COMPOSE_CMD=(sudo --preserve-env=HOME docker compose)
    START_MENU_TESTING=1
    # shellcheck disable=SC1090
    source "$START_SCRIPT"
    unset START_MENU_TESTING
}

setup() {
    mkdir -p "$HOME/dev-env/scripts/runtime" "$HOME/projects"
    mock_binary tmux ""
    mock_binary nproc "2"
    unset DEFAULT_CODE_AGENT CODE_AGENT MAX_SESSIONS
    _source_functions
}

test_count_sessions_zero() {
    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "list-sessions" ]]; then
    exit 1
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"
    _source_functions

    assert_eq "0" "$(count_sessions | head -1)"
}

test_count_sessions_counts_agent_prefix() {
    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "list-sessions" ]]; then
    echo "claude-myrepo"
    echo "codex-other"
    echo "shell-host"
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"
    _source_functions

    assert_eq "2" "$(count_sessions)"
}

test_max_sessions_env_override() {
    assert_eq "5" "$(MAX_SESSIONS=5 get_max_sessions)"
}

test_to_container_path() {
    assert_eq "/home/dev/projects/myrepo" "$(to_container_path "$HOME/projects/myrepo")"
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

test_ensure_claude_state_mount_current_recreates_container_when_mount_is_stale() {
    cat > "$HOME/.claude.json" <<'EOF'
{"state":"fresh"}
EOF
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

test_discover_entries_lists_base_repos_and_tracks_worktrees() {
    local repo
    repo=$(create_test_repo "projects/my-app")
    create_test_worktree "$repo" "feature-x" >/dev/null

    discover_entries

    assert_eq "1" "${#project_entries[@]}"
    assert_eq "2" "${#entries[@]}"
    IFS='|' read -r repo_name branch path kind _repo_warning _repo_refreshing <<< "${project_entries[0]}"
    assert_eq "my-app" "$repo_name"
    assert_eq "$repo" "$path"
    assert_eq "repo" "$kind"

    IFS='|' read -r _ hidden_branch hidden_path hidden_kind <<< "${entries[1]}"
    assert_eq "feature-x" "$hidden_branch"
    assert_eq "${repo}--feature-x" "$hidden_path"
    assert_eq "worktree" "$hidden_kind"
}

test_get_sessions_parses_tmux_metadata() {
    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "list-sessions" ]]; then
    printf 'claude-myrepo\t0\t1711612800\t/home/dev/projects/myrepo--sess-1\tmyrepo\tsess/20260426-120000\toauth fix\n'
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"
    _source_functions

    get_sessions
    assert_eq "1" "${#session_names[@]}"
    assert_eq "claude-myrepo" "${session_names[0]}"
    assert_eq "idle" "${session_states[0]}"
    assert_eq "/home/dev/projects/myrepo--sess-1" "${session_paths[0]}"
    assert_eq "myrepo" "${session_repos[0]}"
    assert_eq "sess/20260426-120000" "${session_branches[0]}"
    assert_eq "oauth fix" "${session_notes[0]}"
}

test_match_sessions_keeps_projects_clean_and_lists_live_sessions_separately() {
    local repo worktree
    repo=$(create_test_repo "projects/myrepo")
    worktree=$(create_test_worktree "$repo" "sess-branch")

    discover_entries
    session_names=("claude-$(basename "$worktree")")
    session_states=("idle")
    session_activities=("1711612800")
    session_paths=("$worktree")
    session_repos=("")
    session_branches=("")

    match_sessions

    assert_eq "1" "${#project_entries[@]}"
    assert_eq "1" "${#session_entries[@]}"
    assert_contains "${session_entries[0]}" "myrepo"
    assert_contains "${session_entries[0]}" "sess-branch"
}

test_match_sessions_includes_note_in_live_session_label() {
    local repo worktree
    repo=$(create_test_repo "projects/myrepo")
    worktree=$(create_test_worktree "$repo" "sess-branch")

    discover_entries
    session_names=("claude-$(basename "$worktree")")
    session_states=("idle")
    session_activities=("1711612800")
    session_paths=("$worktree")
    session_repos=("myrepo")
    session_branches=("sess-branch")
    session_notes=("oauth fix")

    match_sessions

    assert_contains "${session_entries[0]}" "oauth fix"
}

test_match_sessions_lists_inactive_worktree_under_sessions() {
    local repo worktree
    repo=$(create_test_repo "projects/myrepo")
    worktree=$(create_test_worktree "$repo" "feature-x")

    discover_entries
    session_names=()
    session_states=()
    session_activities=()
    session_paths=()
    session_repos=()
    session_branches=()

    match_sessions

    assert_eq "1" "${#project_entries[@]}"
    assert_eq "1" "${#session_entries[@]}"
    assert_contains "${session_entries[0]}" "myrepo  feature-x"
    assert_contains "${session_entries[0]}" "|worktree|"
}

test_show_menu_renders_projects_and_sessions_sections() {
    project_entries=("myrepo|main|/path/myrepo|repo||")
    session_entries=(
        "myrepo  sess/20260426-120000  claude|live|claude-myrepo-sess|idle|1711612800|/path/myrepo--sess|myrepo|sess/20260426-120000|myrepo"
        "myrepo  feature-x|worktree||dormant|0|/path/myrepo--feature-x|myrepo|feature-x|myrepo"
    )

    local output
    output=$(show_menu)

    assert_contains "$output" "Projects"
    assert_contains "$output" "[1] myrepo  main"
    assert_contains "$output" "Sessions"
    assert_contains "$output" "[2] myrepo  sess/20260426-120000  claude  active"
    assert_contains "$output" "[3] myrepo  feature-x  worktree"
}

test_show_menu_renders_session_note() {
    project_entries=("myrepo|main|/path/myrepo|repo||")
    session_entries=("myrepo  sess/20260426-120000  claude  :: oauth fix|live|claude-myrepo-sess|idle|1711612800|/path/myrepo--sess|myrepo|sess/20260426-120000|myrepo")

    local output
    output=$(show_menu)
    assert_contains "$output" "oauth fix"
}

test_show_menu_marks_blocked_projects() {
    project_entries=("myrepo|main|/path/myrepo|repo|needs cleanup|")
    session_entries=()

    local output
    output=$(show_menu)
    assert_contains "$output" "[1] myrepo  main  blocked"
}

test_show_menu_marks_refreshing_projects() {
    project_entries=("myrepo|main|/path/myrepo|repo||refreshing")
    session_entries=()

    local output
    output=$(show_menu)
    assert_contains "$output" "[1] myrepo  main  refreshing"
}

test_select_entry_launches_prepared_worktree_for_project() {
    project_entries=("myrepo|main|/path/myrepo|repo||")
    session_entries=()

    prepare_project_launch() {
        LAUNCH_PATH="/path/myrepo--sess-20260426-120000"
        LAUNCH_BRANCH="sess/20260426-120000"
        LAUNCH_REPO_NAME="myrepo"
    }

    launch() {
        echo "launch:$1|$2|$3"
    }

    local output
    output=$(select_entry 0 2>&1)
    assert_contains "$output" "launch:/path/myrepo--sess-20260426-120000|sess/20260426-120000|myrepo"
}

test_select_entry_launches_existing_worktree_directly() {
    project_entries=("myrepo|main|/path/myrepo|repo||")
    session_entries=("myrepo  sess/20260426-120000|worktree||dormant|0|/path/myrepo--sess|myrepo|sess/20260426-120000|myrepo")

    prepare_project_launch() {
        echo "unexpected prepare" >&2
        return 99
    }

    launch() {
        echo "launch:$1|$2|$3"
    }

    local output
    output=$(select_entry 1 2>&1)
    assert_contains "$output" "launch:/path/myrepo--sess|sess/20260426-120000|myrepo"
}

test_select_entry_attaches_live_session_entry() {
    project_entries=("myrepo|main|/path/myrepo|repo||")
    session_entries=("myrepo  sess/20260426-120000  claude|live|claude-myrepo-sess|idle|1711612800|/path/myrepo--sess|myrepo|sess/20260426-120000|myrepo")

    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "attach-session" && "$2" == "-t" && "$3" == "claude-myrepo-sess" ]]; then
    exit 0
fi
exit 99
MOCK
    chmod +x "$TEST_DIR/bin/tmux"

    local output
    output=$(select_entry 1 2>&1)
    assert_contains "$output" "claude-myrepo-sess"
}

test_session_matches_repo_path_uses_metadata_and_legacy_name_fallback() {
    local repo
    repo=$(create_test_repo "projects/myrepo")

    session_names=("claude-myrepo")
    session_states=("idle")
    session_activities=("1711612800")
    session_paths=("")
    session_repos=("")
    session_branches=("")

    assert_eq "0" "$(session_matches_repo_path "$repo"; echo $?)"

    session_paths=("$repo")
    assert_eq "0" "$(session_matches_repo_path "$repo"; echo $?)"
}

test_run_background_maintenance_skips_base_repo_with_live_session_and_protects_active_worktrees() {
    local repo1 repo2 active_worktree helper
    repo1=$(create_test_repo "projects/repo-one")
    repo2=$(create_test_repo "projects/repo-two")
    active_worktree=$(create_test_worktree "$repo2" "active-work")
    MENU_SYNC_TTL=0
    MENU_CLEANUP_TTL=0

    helper="$TEST_DIR/mock-worktree-helper.sh"
    cat > "$helper" <<MOCK
#!/bin/bash
echo "\$*" >> "$TEST_DIR/markers/helper.log"
case "\$1" in
  cleanup) exit 0 ;;
  sync-repo) exit 0 ;;
esac
exit 0
MOCK
    chmod +x "$helper"
    WORKTREE_HELPER="$helper"

    session_names=("claude-$(basename "$repo1")" "claude-$(basename "$active_worktree")")
    session_states=("idle" "idle")
    session_activities=("1" "2")
    session_paths=("$repo1" "$active_worktree")
    session_repos=("repo-one" "repo-two")
    session_branches=("main" "active-work")

    run_background_maintenance
    for _ in 1 2 3 4 5; do
        [[ -f "$TEST_DIR/markers/helper.log" ]] && break
        sleep 0.2
    done

    local log
    log=$(cat "$TEST_DIR/markers/helper.log")
    assert_contains "$log" "cleanup --quiet --keep-path $repo1 --keep-path $active_worktree"
    [[ "$log" != *"sync-repo $repo1"* ]] || _fail "repo with live base session should not sync"
    assert_contains "$log" "sync-repo $repo2"
}

test_load_maintenance_state_reads_warning_and_refreshing_cache() {
    local repo helper
    repo=$(create_test_repo "projects/repo-one")
    helper="$TEST_DIR/mock-worktree-helper.sh"
    WORKTREE_HELPER="$helper"
    ensure_menu_cache_dirs
    printf '%s\n' "needs cleanup" > "$(repo_warning_file "$repo")"
    : > "$(repo_refreshing_file "$repo")"

    load_maintenance_state

    assert_eq "1" "${#PROJECT_SYNC_WARNINGS[@]}"
    assert_contains "${PROJECT_SYNC_WARNINGS[0]}" "$repo|needs cleanup"
    assert_eq "1" "${#PROJECT_SYNC_REFRESHING[@]}"
    assert_eq "$repo" "${PROJECT_SYNC_REFRESHING[0]}"
}

test_prepare_project_launch_creates_worktree_before_launch() {
    local repo helper
    repo=$(create_test_repo "projects/myrepo")

    helper="$TEST_DIR/mock-worktree-helper.sh"
    cat > "$helper" <<MOCK
#!/bin/bash
echo "\$*" >> "$TEST_DIR/markers/helper.log"
if [[ "\$1" == "cleanup" || "\$1" == "sync-repo" ]]; then
  exit 0
fi
if [[ "\$1" == "create-session-worktree" ]]; then
  echo "$repo--sess-20260426-120000|sess/20260426-120000|main"
  exit 0
fi
exit 0
MOCK
    chmod +x "$helper"
    WORKTREE_HELPER="$helper"

    wait_for_container() { :; }
    session_names=()
    session_states=()
    session_activities=()
    session_paths=()
    session_repos=()
    session_branches=()

    prepare_project_launch "$repo" "myrepo" "main"

    assert_eq "$repo--sess-20260426-120000" "$LAUNCH_PATH"
    assert_eq "sess/20260426-120000" "$LAUNCH_BRANCH"
    assert_eq "myrepo" "$LAUNCH_REPO_NAME"
}

test_prepare_project_launch_recovers_dirty_repo_into_worktree() {
    local repo helper
    repo=$(create_test_repo "projects/myrepo")

    helper="$TEST_DIR/mock-worktree-helper.sh"
    cat > "$helper" <<MOCK
#!/bin/bash
if [[ "\$1" == "sync-repo" ]]; then
  exit 1
fi
if [[ "\$1" == "recover-dirty-repo" ]]; then
  echo "$repo--sess-recover-feature-20260426|sess-recover/feature-20260426"
  exit 0
fi
exit 0
MOCK
    chmod +x "$helper"
    WORKTREE_HELPER="$helper"

    wait_for_container() { :; }
    session_names=()
    session_states=()
    session_activities=()
    session_paths=()
    session_repos=()
    session_branches=()

    prepare_project_launch "$repo" "myrepo" "main"

    assert_eq "$repo--sess-recover-feature-20260426" "$LAUNCH_PATH"
    assert_eq "sess-recover/feature-20260426" "$LAUNCH_BRANCH"
    assert_eq "myrepo" "$LAUNCH_REPO_NAME"
}

test_prepare_project_launch_blocks_when_base_repo_has_live_session() {
    local repo
    repo=$(create_test_repo "projects/myrepo")
    wait_for_container() { :; }
    session_names=("claude-myrepo")
    session_states=("idle")
    session_activities=("1")
    session_paths=("$repo")
    session_repos=("myrepo")
    session_branches=("main")

    local output exit_code=0
    output=$(prepare_project_launch "$repo" "myrepo" "main" 2>&1) || exit_code=$?
    assert_eq "1" "$exit_code"
    assert_contains "$output" "live tmux session"
}

# --- file_age_seconds / cleanup_due ---

test_file_age_seconds_returns_positive_integer_for_recent_file() {
    local f="$TEST_DIR/recent"
    touch "$f"

    local age
    age=$(file_age_seconds "$f")
    [[ "$age" =~ ^[0-9]+$ ]] || _fail "expected integer, got '$age'"
    [[ "$age" -lt 60 ]] || _fail "expected age <60s for just-touched file, got $age"
}

test_file_age_seconds_handles_old_file() {
    local f="$TEST_DIR/old"
    touch -d '2026-01-01 00:00:00' "$f"

    local age
    age=$(file_age_seconds "$f")
    [[ "$age" =~ ^[0-9]+$ ]] || _fail "expected integer, got '$age'"
    [[ "$age" -gt 86400 ]] || _fail "expected age >1 day for Jan 1 file, got $age"
}

test_file_age_seconds_returns_nonzero_for_missing_file() {
    local exit_code=0
    file_age_seconds "$TEST_DIR/does-not-exist" >/dev/null 2>&1 || exit_code=$?
    [[ "$exit_code" -ne 0 ]] || _fail "expected non-zero exit for missing file"
}

test_cleanup_due_true_when_stamp_is_old() {
    # Regression: file_age_seconds used `stat -f %m` first, which on GNU
    # systems exits 0 with a multi-line filesystem dump instead of an
    # mtime. The arithmetic on that string aborted the surrounding
    # subshell under `set -u`, the `|| echo TTL+1` fallback never ran,
    # and cleanup_due always returned false on Linux — so picker-driven
    # cleanup never fired.
    MENU_CACHE_DIR="$TEST_DIR/cache"
    MENU_CLEANUP_TTL=300
    mkdir -p "$MENU_CACHE_DIR"
    touch -d '2026-01-01 00:00:00' "$MENU_CACHE_DIR/cleanup.stamp"

    cleanup_due || _fail "cleanup_due should be true when stamp is months old"
}

test_cleanup_due_false_when_stamp_is_fresh() {
    MENU_CACHE_DIR="$TEST_DIR/cache"
    MENU_CLEANUP_TTL=300
    mkdir -p "$MENU_CACHE_DIR"
    touch "$MENU_CACHE_DIR/cleanup.stamp"

    if cleanup_due; then
        _fail "cleanup_due should be false for just-touched stamp"
    fi
}

test_cleanup_due_true_when_stamp_missing() {
    MENU_CACHE_DIR="$TEST_DIR/cache-empty"
    MENU_CLEANUP_TTL=300
    mkdir -p "$MENU_CACHE_DIR"

    cleanup_due || _fail "cleanup_due should be true when stamp is missing"
}
