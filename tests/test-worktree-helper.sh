#!/bin/bash
# Tests for scripts/runtime/worktree-helper.sh

HELPER="$REPO_ROOT/scripts/runtime/worktree-helper.sh"

# Override HOME/projects to TEST_DIR for find discovery.
# Unset DEV_ENV/PROJECTS_DIR so the helper doesn't load /home/dev/dev-env/.env
# and override paths to the real workspace (would leak host state into tests).
setup() {
    unset DEV_ENV PROJECTS_DIR
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
    assert_eq "1" "$(printf '%s\n' "$output" | grep -c 'dev-branch')"
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

test_default_branch_prefers_remote_head() {
    local repo bare
    repo=$(create_test_repo projects/myrepo)
    bare="$TEST_DIR/bare-remote"
    git init -q --bare "$bare"
    git -C "$repo" branch -M trunk
    git -C "$repo" remote add origin "$bare"
    git -C "$repo" push -q -u origin trunk
    git --git-dir="$bare" symbolic-ref HEAD refs/heads/trunk
    git -C "$repo" fetch -q origin
    git -C "$repo" remote set-head origin -a >/dev/null 2>&1 || true

    local output
    output=$(bash "$HELPER" default-branch "$repo")
    assert_eq "trunk" "$output"
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

test_create_session_worktree_uses_session_branch_prefix() {
    local repo output path branch default_branch
    repo=$(create_test_repo projects/myrepo)

    output=$(bash "$HELPER" create-session-worktree "$repo")
    IFS='|' read -r path branch default_branch <<< "$output"

    assert_contains "$path" "$repo--sess-"
    assert_contains "$branch" "sess/"
    assert_eq "$(git -C "$repo" branch --show-current)" "$default_branch"
    assert_file_exists "$path/.git"
}

test_recover_dirty_repo_moves_changes_to_recovery_worktree() {
    local repo output path branch
    repo=$(create_test_repo projects/myrepo)
    git -C "$repo" checkout -q -b feature-work
    echo "dirty" > "$repo/dirty.txt"

    output=$(bash "$HELPER" recover-dirty-repo "$repo")
    IFS='|' read -r path branch <<< "$output"

    assert_contains "$branch" "sess-recover/"
    assert_file_exists "$path/.git"
    assert_file_exists "$path/dirty.txt"
    assert_file_not_exists "$repo/dirty.txt"
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

test_cleanup_keeps_active_session_worktree() {
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

    bash "$HELPER" cleanup --keep-path "$HOME/projects/myrepo--merged-branch" >/dev/null
    assert_file_exists "$HOME/projects/myrepo--merged-branch/.git"
}

test_cleanup_removes_worktree_with_no_unique_commits_when_main_moves_ahead() {
    local repo
    repo=$(create_test_repo projects/myrepo)
    create_test_worktree "$repo" "idle-branch"

    touch "$repo/mainfile"
    git -C "$repo" add mainfile
    git -C "$repo" commit -q -m "main moved"

    local bare="$TEST_DIR/bare-remote"
    git init -q --bare "$bare"
    git -C "$repo" remote add origin "$bare" 2>/dev/null || true
    local default_branch
    default_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
    git -C "$repo" push -q origin "${default_branch}" 2>/dev/null || true

    bash "$HELPER" cleanup >/dev/null
    assert_file_not_exists "$HOME/projects/myrepo--idle-branch"
}

test_cleanup_keeps_worktree_with_local_edits_even_without_unique_commits() {
    local repo
    repo=$(create_test_repo projects/myrepo)
    create_test_worktree "$repo" "dirty-branch"

    touch "$repo/mainfile"
    git -C "$repo" add mainfile
    git -C "$repo" commit -q -m "main moved"

    echo "dirty" > "$HOME/projects/myrepo--dirty-branch/local.txt"

    local bare="$TEST_DIR/bare-remote"
    git init -q --bare "$bare"
    git -C "$repo" remote add origin "$bare" 2>/dev/null || true
    local default_branch
    default_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
    git -C "$repo" push -q origin "${default_branch}" 2>/dev/null || true

    local output
    output=$(bash "$HELPER" cleanup --dry-run)
    assert_contains "$output" "$HOME/projects/myrepo--dirty-branch (local edits)"
    [[ "$output" != *"myrepo--dirty-branch (no unique commits beyond"* ]] || _fail "dirty worktree should not be cleanup candidate"
    assert_file_exists "$HOME/projects/myrepo--dirty-branch/.git"
}

test_cleanup_removes_lingering_orphan_dir_after_git_cleanup() {
    local repo worktree log
    repo="$HOME/projects/myrepo"
    worktree="$HOME/projects/myrepo--sess-20260426-000000"
    mkdir -p "$repo/.git" "$worktree"
    printf 'gitdir: /home/dev/projects/myrepo/.git/worktrees/myrepo--sess-20260426-000000\n' > "$worktree/.git"

    log="$TEST_DIR/markers/git.log"
    cat > "$TEST_DIR/bin/git" <<MOCK
#!/bin/bash
echo "\$*" >> "$log"
if [[ "\$1" == "-C" ]]; then
  repo="\$2"
  shift 2
fi
case "\$1 \$2 \$3 \$4" in
  "fetch origin main ")
    exit 0
    ;;
  "worktree list --porcelain ")
    printf 'worktree %s\nHEAD deadbeef\nbranch refs/heads/main\n\nworktree %s\nHEAD deadbeef\nbranch refs/heads/sess/20260426-000000\n\n' "$repo" "$worktree"
    exit 0
    ;;
  "worktree remove $worktree ")
    exit 0
    ;;
  "worktree prune  ")
    exit 0
    ;;
  "show-ref --verify --quiet refs/remotes/origin/main")
    exit 1
    ;;
  "show-ref --verify --quiet refs/heads/main")
    exit 0
    ;;
  "rev-parse --verify main ")
    exit 0
    ;;
  "rev-list --count main..sess/20260426-000000")
    echo 0
    exit 0
    ;;
  "status --porcelain  ")
    exit 0
    ;;
esac
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/git"

    bash "$HELPER" cleanup >/dev/null
    assert_file_not_exists "$worktree"
}

test_cleanup_removes_orphan_sibling_with_stale_gitdir() {
    local repo
    repo=$(create_test_repo projects/myrepo)
    create_test_worktree "$repo" "orphan-branch"

    # Simulate the "gitdir gone but worktree dir remains" failure mode:
    # delete the .git/worktrees/<name> entry so the .git file in the worktree
    # points at a path that no longer exists.
    rm -rf "$repo/.git/worktrees/myrepo--orphan-branch"

    local bare="$TEST_DIR/bare-remote"
    git init -q --bare "$bare"
    git -C "$repo" remote add origin "$bare" 2>/dev/null || true
    local default_branch
    default_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
    git -C "$repo" push -q origin "${default_branch}" 2>/dev/null || true

    bash "$HELPER" cleanup >/dev/null
    assert_file_not_exists "$HOME/projects/myrepo--orphan-branch"
}

test_cleanup_dirty_but_merged_worktree_is_flagged_not_removed() {
    local repo
    repo=$(create_test_repo projects/myrepo)
    create_test_worktree "$repo" "idle-dirty"

    # Advance main so the branch has no unique commits beyond it.
    touch "$repo/mainfile"
    git -C "$repo" add mainfile
    git -C "$repo" commit -q -m "main moves"

    # Worktree has uncommitted local edits.
    echo "scratch" > "$HOME/projects/myrepo--idle-dirty/scratch.txt"

    local bare="$TEST_DIR/bare-remote"
    git init -q --bare "$bare"
    git -C "$repo" remote add origin "$bare" 2>/dev/null || true
    local default_branch
    default_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
    git -C "$repo" push -q origin "${default_branch}" 2>/dev/null || true

    local output
    output=$(bash "$HELPER" cleanup)
    assert_contains "$output" "Dirty but merged"
    assert_contains "$output" "myrepo--idle-dirty (merged, but has local edits"
    assert_file_exists "$HOME/projects/myrepo--idle-dirty/.git"
}

test_cleanup_pre_prune_runs_before_main_loop() {
    # Verify the pre-prune pass clears a stale .git/worktrees/<name> entry
    # before the orphan-sibling scan tries to inspect the on-disk dir.
    local repo
    repo=$(create_test_repo projects/myrepo)
    create_test_worktree "$repo" "ghost"

    # Move the worktree dir out of the way so it looks "missing" to git, but
    # keep the .git/worktrees/<name> entry so it shows up in `worktree list`
    # as prunable. After pre-prune, the entry should be gone.
    mv "$HOME/projects/myrepo--ghost" "$HOME/projects/myrepo--ghost.away"

    local bare="$TEST_DIR/bare-remote"
    git init -q --bare "$bare"
    git -C "$repo" remote add origin "$bare" 2>/dev/null || true
    local default_branch
    default_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
    git -C "$repo" push -q origin "${default_branch}" 2>/dev/null || true

    bash "$HELPER" cleanup >/dev/null

    # Pre-prune should have removed the registration.
    [[ ! -d "$repo/.git/worktrees/myrepo--ghost" ]] || _fail "pre-prune did not clear .git/worktrees/myrepo--ghost"
}

test_cleanup_processes_all_repos_when_inner_git_reads_stdin() {
    # Regression: the outer find-pipe was being slurped by `git fetch`
    # inside the loop because fetch inherited FD 0. That silently skipped
    # every repo after the first one, leaving merged worktrees in place.
    # Set up three repos in alphabetical order, each with a mergeable
    # worktree, and wrap git so `fetch` reads stdin. All three worktrees
    # must be cleaned, not just the first.
    local real_git
    real_git=$(command -v git)

    local name repo bare default_branch
    for name in alpha bravo charlie; do
        repo=$(create_test_repo "projects/$name")
        create_test_worktree "$repo" "merged" >/dev/null
        bare="$TEST_DIR/bare-$name"
        git init -q --bare "$bare"
        git -C "$repo" remote add origin "$bare"
        default_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
        git -C "$repo" push -q origin "${default_branch}"
    done

    cat > "$TEST_DIR/bin/git" <<WRAP
#!/bin/bash
# Slurp one line of stdin during fetch — emulates the conditions under
# which real git reads from the controlling terminal (askpass, slow
# handshake). If the cleanup loop hasn't isolated stdin, this consumes
# a path off the find pipe and the next repo gets skipped.
for arg in "\$@"; do
    if [[ "\$arg" == "fetch" ]]; then
        IFS= read -r -t 0.05 _slurp 2>/dev/null || true
        break
    fi
done
exec "$real_git" "\$@"
WRAP
    chmod +x "$TEST_DIR/bin/git"

    bash "$HELPER" cleanup >/dev/null

    # Roll up failures so a single missed repo is visible; with bare
    # asserts, set -e is suppressed inside the test function so only
    # the last assertion's exit code would matter.
    local missing=()
    for name in alpha bravo charlie; do
        [[ ! -e "$HOME/projects/${name}--merged" ]] || missing+=("${name}--merged")
    done
    [[ ${#missing[@]} -eq 0 ]] || _fail "worktrees not cleaned: ${missing[*]}"
}

test_sync_repo_resets_to_default_branch_and_cleans_files() {
    local repo
    repo=$(create_test_repo projects/myrepo)
    local initial_branch
    initial_branch=$(git -C "$repo" branch --show-current)
    git -C "$repo" checkout -q -b feature-work
    touch "$repo/extra"

    local output
    output=$(bash "$HELPER" sync-repo "$repo")

    assert_contains "$output" "$repo|"
    assert_eq "$initial_branch" "$(git -C "$repo" branch --show-current)"
    assert_file_not_exists "$repo/extra"
}
