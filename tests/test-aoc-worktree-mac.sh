#!/bin/bash
# Tests for scripts/runtime/aoc-worktree-mac.sh

SCRIPT="$REPO_ROOT/scripts/runtime/aoc-worktree-mac.sh"

setup() {
    mkdir -p "$HOME/projects"
}

test_list_repos_routes_through_container_and_translates_paths() {
    cat > "$TEST_DIR/bin/docker" <<'MOCK'
#!/bin/bash
if [[ "$1" == "ps" ]]; then
  echo "claude-dev"
  exit 0
fi
if [[ "$1" == "exec" ]]; then
  echo "REPO|/home/dev/projects/myrepo|main"
  exit 0
fi
exit 1
MOCK
    chmod +x "$TEST_DIR/bin/docker"

    local output
    output=$(DOCKER="$TEST_DIR/bin/docker" bash "$SCRIPT" list-repos)
    assert_contains "$output" "REPO|$HOME/projects/myrepo|main"
}

test_cleanup_translates_keep_path_to_container() {
    cat > "$TEST_DIR/bin/docker" <<'MOCK'
#!/bin/bash
if [[ "$1" == "ps" ]]; then
  echo "claude-dev"
  exit 0
fi
if [[ "$1" == "exec" ]]; then
  printf '%s\n' "$*"
  exit 0
fi
exit 1
MOCK
    chmod +x "$TEST_DIR/bin/docker"

    local output
    output=$(DOCKER="$TEST_DIR/bin/docker" AOC_PROJECTS_HOST="$HOME/projects" bash "$SCRIPT" cleanup --dry-run --keep-path "$HOME/projects/myrepo--sess")
    assert_contains "$output" "--keep-path $HOME/projects/myrepo--sess"
}

test_status_runs_git_inside_container() {
    cat > "$TEST_DIR/bin/docker" <<'MOCK'
#!/bin/bash
if [[ "$1" == "ps" ]]; then
  echo "claude-dev"
  exit 0
fi
if [[ "$1" == "exec" ]]; then
  echo "## sess-recover/example"
  echo " M file.js"
  exit 0
fi
exit 1
MOCK
    chmod +x "$TEST_DIR/bin/docker"

    local output
    output=$(DOCKER="$TEST_DIR/bin/docker" bash "$SCRIPT" status "$HOME/projects/myrepo--sess-recover")
    assert_contains "$output" "## sess-recover/example"
    assert_contains "$output" " M file.js"
}

test_overview_shows_sessions_and_blocked_repos() {
    mkdir -p "$TEST_DIR/cache/warnings" "$TEST_DIR/cache/refreshing"
    local repo
    repo=$(create_test_repo "projects/myrepo")
    printf '%s\n' "needs cleanup" > "$TEST_DIR/cache/warnings/$(echo "$repo" | tr '/:' '__')"
    : > "$TEST_DIR/cache/cleanup.stamp"

    cat > "$TEST_DIR/bin/docker" <<'MOCK'
#!/bin/bash
if [[ "$1" == "ps" ]]; then
  echo "claude-dev"
  exit 0
fi
if [[ "$1" == "exec" ]]; then
  echo ""
  echo "=== Worktree Cleanup (dry run) ==="
  echo ""
  echo "  Cleaned: (none)"
  echo ""
  echo "  Stale: (none)"
  echo ""
  echo "  Active: (none)"
  exit 0
fi
exit 1
MOCK
    chmod +x "$TEST_DIR/bin/docker"

    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
if [[ "$1" == "list-sessions" ]]; then
  printf 'claude-myrepo\t0\t/path/myrepo--sess\tmyrepo\tsess/1\n'
  exit 0
fi
exit 1
MOCK
    chmod +x "$TEST_DIR/bin/tmux"

    local output
    output=$(DOCKER="$TEST_DIR/bin/docker" AOC_PROJECTS_HOST="$HOME/projects" AOC_MENU_CACHE_DIR="$TEST_DIR/cache" bash "$SCRIPT" overview)
    assert_contains "$output" "Sessions"
    assert_contains "$output" "claude-myrepo  idle  myrepo  sess/1"
    assert_contains "$output" "Blocked repos"
    assert_contains "$output" "$repo  needs cleanup"
    assert_contains "$output" "=== Worktree Cleanup (dry run) ==="
}
