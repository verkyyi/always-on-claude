#!/bin/bash
# Tests for scripts/portable/start-claude-portable.sh

PORTABLE_SCRIPT="$REPO_ROOT/scripts/portable/start-claude-portable.sh"

_source_functions() {
    export DEV_ENV="$REPO_ROOT"
    export PROJECTS_DIR="$HOME/projects"
    export DEFAULT_CODE_AGENT="${DEFAULT_CODE_AGENT:-claude}"
    export CODE_AGENT="${CODE_AGENT:-$DEFAULT_CODE_AGENT}"
    START_MENU_TESTING=1
    # shellcheck disable=SC1090
    source "$PORTABLE_SCRIPT"
    unset START_MENU_TESTING
}

setup() {
    mkdir -p "$HOME/projects"
    mock_binary tmux ""
    mock_binary nproc "2"
    unset DEFAULT_CODE_AGENT CODE_AGENT MAX_SESSIONS
    _source_functions
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

test_get_sessions_filters_non_agent_sessions() {
    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "list-sessions" ]]; then
    printf 'claude-app\t0\t1\t/path/app--sess\tapp\tsess/1\n'
    printf 'codex-api\t1\t2\t/path/api--sess\tapi\tsess/2\n'
    printf 'shell-local\t0\t3\t\t\t\n'
fi
MOCK
    chmod +x "$TEST_DIR/bin/tmux"
    _source_functions

    get_sessions
    assert_eq "2" "${#session_names[@]}"
    assert_eq "attached" "${session_states[1]}"
}

test_launch_sets_tmux_session_metadata() {
    export TMUX_LOG="$TEST_DIR/markers/tmux.log"
    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
echo "$1|$2|$3|$AOC_SESSION_PATH|$AOC_SESSION_REPO|$AOC_SESSION_BRANCH" >> "$TMUX_LOG"
if [[ "$1" == "has-session" ]]; then
    exit 1
fi
if [[ "$1" == "attach-session" ]]; then
    exit 0
fi
if [[ "$1" == "new-session" || "$1" == "set-option" || "$1" == "detach-client" ]]; then
    exit 0
fi
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/tmux"
    _source_functions

    launch "/path/myrepo--sess-1" "sess/1" "myrepo" >/dev/null

    local log
    log=$(cat "$TEST_DIR/markers/tmux.log")
    assert_contains "$log" "new-session|-d|-s|/path/myrepo--sess-1|myrepo|sess/1"
    assert_contains "$log" "set-option|-t|claude-myrepo--sess-1|/path/myrepo--sess-1|myrepo|sess/1"
}

test_run_background_maintenance_skips_live_base_repo_sessions() {
    local repo1 repo2 helper
    repo1=$(create_test_repo "projects/repo-one")
    repo2=$(create_test_repo "projects/repo-two")
    MENU_SYNC_TTL=0
    MENU_CLEANUP_TTL=0

    helper="$TEST_DIR/mock-worktree-helper.sh"
    cat > "$helper" <<MOCK
#!/bin/bash
echo "\$*" >> "$TEST_DIR/markers/helper.log"
exit 0
MOCK
    chmod +x "$helper"
    WORKTREE_HELPER="$helper"

    session_names=("claude-$(basename "$repo1")")
    session_states=("idle")
    session_activities=("1")
    session_paths=("$repo1")
    session_repos=("repo-one")
    session_branches=("main")

    run_background_maintenance
    for _ in 1 2 3 4 5; do
        [[ -f "$TEST_DIR/markers/helper.log" ]] && break
        sleep 0.2
    done

    local log
    log=$(cat "$TEST_DIR/markers/helper.log")
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

test_prepare_project_launch_creates_auto_worktree() {
    local repo helper
    repo=$(create_test_repo "projects/myrepo")

    helper="$TEST_DIR/mock-worktree-helper.sh"
    cat > "$helper" <<MOCK
#!/bin/bash
if [[ "\$1" == "cleanup" || "\$1" == "sync-repo" ]]; then
  exit 0
fi
if [[ "\$1" == "create-session-worktree" ]]; then
  echo "$repo--sess-20260426-130000|sess/20260426-130000|main"
  exit 0
fi
exit 0
MOCK
    chmod +x "$helper"
    WORKTREE_HELPER="$helper"

    session_names=()
    session_states=()
    session_activities=()
    session_paths=()
    session_repos=()
    session_branches=()

    prepare_project_launch "$repo" "myrepo" "main"

    assert_eq "$repo--sess-20260426-130000" "$LAUNCH_PATH"
    assert_eq "sess/20260426-130000" "$LAUNCH_BRANCH"
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
