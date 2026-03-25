#!/bin/bash
# Tests for scripts/runtime/worktree-helper.sh

HELPER="$REPO_ROOT/scripts/runtime/worktree-helper.sh"

# Override HOME/projects to TEST_DIR for find discovery
setup() {
    mkdir -p "$HOME/projects"
}

# --- list-repos ---

test_list_repos_finds_repos() {
    local repo1
    repo1=$(create_test_repo projects/repo1)
    local repo2
    mkdir -p "$HOME/projects/org"
    repo2="$HOME/projects/org/repo2"
    git init -q "$repo2"
    git -C "$repo2" config user.name "Test"
    git -C "$repo2" config user.email "test@test.com"
    touch "$repo2/file"
    git -C "$repo2" add . && git -C "$repo2" commit -q -m "init"

    local output
    output=$(bash "$HELPER" list-repos)
    assert_contains "$output" "REPO|$HOME/projects/repo1|"
    assert_contains "$output" "REPO|$HOME/projects/org/repo2|"
}

test_list_repos_ignores_deep_repos() {
    mkdir -p "$HOME/projects/a/b/c"
    local deep="$HOME/projects/a/b/c/deep-repo"
    git init -q "$deep"
    git -C "$deep" config user.name "Test"
    git -C "$deep" config user.email "test@test.com"
    touch "$deep/file"
    git -C "$deep" add . && git -C "$deep" commit -q -m "init"

    local output
    output=$(bash "$HELPER" list-repos)
    [[ "$output" != *"deep-repo"* ]] || _fail "deep repo should not be discovered"
}

test_list_repos_distinguishes_repo_vs_worktree() {
    local repo
    repo=$(create_test_repo projects/myrepo)
    create_test_worktree "$repo" "feature-branch"

    local output
    output=$(bash "$HELPER" list-repos)
    assert_contains "$output" "REPO|$HOME/projects/myrepo|"
    assert_contains "$output" "WORKTREE|$HOME/projects/myrepo--feature-branch|"
}

# --- list-worktrees ---

test_list_worktrees_returns_branches() {
    local repo
    repo=$(create_test_repo projects/myrepo)
    create_test_worktree "$repo" "dev-branch"

    local output
    output=$(bash "$HELPER" list-worktrees "$repo")
    assert_contains "$output" "dev-branch"
    assert_contains "$output" "$HOME/projects/myrepo--dev-branch"
}

test_list_worktrees_skips_detached_head() {
    local repo
    repo=$(create_test_repo projects/myrepo)
    local sha
    sha=$(git -C "$repo" rev-parse HEAD)
    git -C "$repo" worktree add --detach "$repo--detached" "$sha" 2>/dev/null

    local output
    output=$(bash "$HELPER" list-worktrees "$repo")
    [[ "$output" != *"detached"* ]] || _fail "detached HEAD worktree should be skipped"
}

# --- create ---

test_create_worktree() {
    local repo
    repo=$(create_test_repo projects/myrepo)

    local output
    output=$(bash "$HELPER" create "$repo" "new-branch" | tail -1)
    assert_eq "$repo--new-branch" "$output"
    assert_file_exists "$repo--new-branch/.git"
}

test_create_worktree_sanitizes_branch() {
    local repo
    repo=$(create_test_repo projects/myrepo)

    local output
    output=$(bash "$HELPER" create "$repo" "feature/foo" | tail -1)
    assert_eq "$repo--feature-foo" "$output"
    assert_file_exists "$repo--feature-foo/.git"
}

# --- remove ---

test_remove_worktree() {
    local repo
    repo=$(create_test_repo projects/myrepo)
    create_test_worktree "$repo" "to-remove"
    assert_file_exists "$repo--to-remove/.git"

    bash "$HELPER" remove "$repo--to-remove"
    assert_file_not_exists "$repo--to-remove"
}

test_remove_rejects_non_worktree() {
    local repo
    repo=$(create_test_repo projects/myrepo)
    assert_exit_code 1 bash "$HELPER" remove "$repo"
}

# --- cleanup ---

test_cleanup_dry_run() {
    local repo
    repo=$(create_test_repo projects/myrepo)
    create_test_worktree "$repo" "merged-branch"

    git -C "$repo" merge --no-edit "$HOME/projects/myrepo--merged-branch" 2>/dev/null || true
    local bare="$TEST_DIR/bare-remote"
    git init -q --bare "$bare"
    git -C "$repo" remote add origin "$bare" 2>/dev/null || true
    # Push to the detected default branch (master or main)
    local default_branch
    default_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
    git -C "$repo" push -q origin "${default_branch}" 2>/dev/null || true

    local output
    output=$(bash "$HELPER" cleanup --dry-run)
    assert_contains "$output" "dry-run"
    assert_file_exists "$HOME/projects/myrepo--merged-branch/.git"
}

test_cleanup_removes_merged() {
    local repo
    repo=$(create_test_repo projects/myrepo)
    create_test_worktree "$repo" "merged-branch"

    touch "$HOME/projects/myrepo--merged-branch/newfile"
    git -C "$HOME/projects/myrepo--merged-branch" add .
    git -C "$HOME/projects/myrepo--merged-branch" commit -q -m "worktree commit"

    git -C "$repo" merge --no-edit merged-branch 2>/dev/null || true

    local bare="$TEST_DIR/bare-remote"
    git init -q --bare "$bare"
    git -C "$repo" remote add origin "$bare" 2>/dev/null || true
    local default_branch
    default_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
    git -C "$repo" push -q origin "${default_branch}" 2>/dev/null || true

    bash "$HELPER" cleanup >/dev/null
    assert_file_not_exists "$HOME/projects/myrepo--merged-branch"
}

test_cleanup_force_removes_stale() {
    local repo
    repo=$(create_test_repo projects/myrepo)
    create_test_worktree "$repo" "stale-branch"

    touch "$HOME/projects/myrepo--stale-branch/oldfile"
    git -C "$HOME/projects/myrepo--stale-branch" add .
    GIT_COMMITTER_DATE="2026-03-01T00:00:00" git -C "$HOME/projects/myrepo--stale-branch" commit -q -m "old commit" --date="2026-03-01T00:00:00"

    local bare="$TEST_DIR/bare-remote"
    git init -q --bare "$bare"
    git -C "$repo" remote add origin "$bare" 2>/dev/null || true
    local default_branch
    default_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
    git -C "$repo" push -q origin "${default_branch}" 2>/dev/null || true

    bash "$HELPER" cleanup --force >/dev/null
    assert_file_not_exists "$HOME/projects/myrepo--stale-branch"
}

test_cleanup_keeps_recent() {
    local repo
    repo=$(create_test_repo projects/myrepo)
    create_test_worktree "$repo" "active-branch"

    touch "$HOME/projects/myrepo--active-branch/newfile"
    git -C "$HOME/projects/myrepo--active-branch" add .
    git -C "$HOME/projects/myrepo--active-branch" commit -q -m "fresh commit"

    local bare="$TEST_DIR/bare-remote"
    git init -q --bare "$bare"
    git -C "$repo" remote add origin "$bare" 2>/dev/null || true
    local default_branch
    default_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
    git -C "$repo" push -q origin "${default_branch}" 2>/dev/null || true

    bash "$HELPER" cleanup >/dev/null
    assert_file_exists "$HOME/projects/myrepo--active-branch/.git"
}
