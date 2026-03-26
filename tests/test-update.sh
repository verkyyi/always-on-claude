#!/bin/bash
# Tests for scripts/runtime/update.sh

UPDATE_SCRIPT="$REPO_ROOT/scripts/runtime/update.sh"

setup() {
    git init -q --bare "$TEST_DIR/remote.git"
    git clone -q "$TEST_DIR/remote.git" "$HOME/dev-env"
    git -C "$HOME/dev-env" config user.name "Test"
    git -C "$HOME/dev-env" config user.email "test@test.com"
    touch "$HOME/dev-env/README.md"
    git -C "$HOME/dev-env" add .
    git -C "$HOME/dev-env" commit -q -m "Initial commit"
    git -C "$HOME/dev-env" push -q origin main 2>/dev/null || \
        git -C "$HOME/dev-env" push -q origin master 2>/dev/null || true
}

_push_upstream_commit() {
    local other="$TEST_DIR/other-clone"
    [[ -d "$other" ]] && rm -rf "$other"
    git clone -q "$TEST_DIR/remote.git" "$other"
    git -C "$other" config user.name "Other"
    git -C "$other" config user.email "other@test.com"
    touch "$other/$1"
    git -C "$other" add .
    git -C "$other" commit -q -m "${2:-Upstream change}"
    git -C "$other" push -q origin 2>/dev/null
}

test_creates_pending_on_new_commits() {
    _push_upstream_commit "newfile" "Upstream change"
    bash "$UPDATE_SCRIPT"
    assert_file_exists "$HOME/.update-pending"
}

test_pending_contains_shas() {
    _push_upstream_commit "anotherfile" "Another change"
    bash "$UPDATE_SCRIPT"
    local content
    content=$(cat "$HOME/.update-pending")
    assert_contains "$content" "before="
    assert_contains "$content" "after="
}

test_pending_contains_log() {
    _push_upstream_commit "logfile" "Commit with unique message XYZ123"
    bash "$UPDATE_SCRIPT"
    local content
    content=$(cat "$HOME/.update-pending")
    assert_contains "$content" "XYZ123"
}

test_noop_when_up_to_date() {
    bash "$UPDATE_SCRIPT"
    assert_file_not_exists "$HOME/.update-pending"
}

test_fetch_does_not_modify_working_tree() {
    _push_upstream_commit "upstream-file" "Upstream change"
    bash "$UPDATE_SCRIPT"
    # The new file should NOT be in the local working tree (fetch only, no pull)
    assert_file_not_exists "$HOME/dev-env/upstream-file"
}

test_local_head_unchanged_after_check() {
    local before
    before=$(git -C "$HOME/dev-env" rev-parse HEAD)
    _push_upstream_commit "somefile" "New commit"
    bash "$UPDATE_SCRIPT"
    local after
    after=$(git -C "$HOME/dev-env" rev-parse HEAD)
    assert_eq "$before" "$after" "local HEAD should not change after fetch-only check"
}

test_clears_pending_when_up_to_date() {
    # Create a stale pending file
    echo "stale=true" > "$HOME/.update-pending"
    bash "$UPDATE_SCRIPT"
    assert_file_not_exists "$HOME/.update-pending"
}

test_exits_when_not_git_repo() {
    rm -rf "$HOME/dev-env/.git"
    assert_exit_code 1 bash "$UPDATE_SCRIPT"
}
