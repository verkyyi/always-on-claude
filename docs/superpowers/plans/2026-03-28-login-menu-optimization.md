# Login Menu Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the SSH login workspace picker for speed, visual clarity, flat navigation, and smart defaults

**Architecture:** Single-file rewrite of `scripts/runtime/start-claude.sh`. Tasks 1-4 add new functions alongside existing ones (script stays functional). Task 5 swaps the main loop and removes old code. Task 6 updates tests and verifies. TDD: tests written before implementation.

**Tech Stack:** Bash 4+, tmux, git, Docker

**Spec:** `docs/superpowers/specs/2026-03-28-login-menu-optimization-design.md`

---

### Task 1: Inline Discovery with Parallel Git

**Files:**
- Modify: `scripts/runtime/start-claude.sh` (add `discover_entries()` function, add `PROJECTS_DIR` config)
- Modify: `tests/test-start-claude.sh` (add `_source_v2` helper and discovery tests)

- [ ] **Step 1: Write failing tests for `discover_entries()`**

Add to the top of `tests/test-start-claude.sh`, after the existing `_source_functions`:

```bash
_source_v2() {
    export PROJECTS_DIR="$HOME/projects"
    eval "$(sed -n '/^discover_entries()/,/^}/p' "$START_SCRIPT")" 2>/dev/null || true
    eval "$(sed -n '/^get_sessions()/,/^}/p' "$START_SCRIPT")" 2>/dev/null || true
    eval "$(sed -n '/^match_sessions()/,/^}/p' "$START_SCRIPT")" 2>/dev/null || true
    eval "$(sed -n '/^compute_default()/,/^}/p' "$START_SCRIPT")" 2>/dev/null || true
    eval "$(sed -n '/^show_menu()/,/^}/p' "$START_SCRIPT")" 2>/dev/null || true
}
```

Update the existing `setup()` to also call `_source_v2`:

```bash
setup() {
    mkdir -p "$HOME/dev-env/scripts/runtime" "$HOME/projects"
    mock_binary tmux ""
    mock_binary nproc "2"
    _source_functions
    _source_v2
}
```

Add these test functions at the end of the file:

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run.sh tests/test-start-claude.sh`
Expected: The 4 new tests FAIL (discover_entries not found), existing tests still PASS

- [ ] **Step 3: Implement `discover_entries()` in start-claude.sh**

Add `PROJECTS_DIR` default after the existing config loading block (after line 19, before `CONTAINER_NAME`):

```bash
: "${PROJECTS_DIR:=$HOME/projects}"
```

Add the function after `to_container_path()` (after the existing helper functions, before the `# --- Discover repos and worktrees ---` section):

```bash
# --- Inline discovery (flat: repos + worktrees in one pass) ---
discover_entries() {
    entries=()
    local repo_dirs=()
    mapfile -t repo_dirs < <(find "$PROJECTS_DIR" -maxdepth 3 -name ".git" -type d 2>/dev/null | sort)

    [[ ${#repo_dirs[@]} -eq 0 ]] && return

    # Parallel git branch queries
    local tmpdir
    tmpdir=$(mktemp -d)
    for i in "${!repo_dirs[@]}"; do
        local dir
        dir=$(dirname "${repo_dirs[$i]}")
        ( git -C "$dir" branch --show-current 2>/dev/null || echo "unknown" ) > "$tmpdir/$i" &
    done
    wait

    for i in "${!repo_dirs[@]}"; do
        local dir
        dir=$(dirname "${repo_dirs[$i]}")
        local branch
        branch=$(cat "$tmpdir/$i")
        local repo_name
        repo_name=$(basename "$dir")

        # Add main repo entry: repo_name|branch|path|session_state|session_activity
        entries+=("${repo_name}|${branch}|${dir}|none|0")

        # Discover worktrees for this repo
        local wt_path="" wt_branch=""
        while IFS= read -r line; do
            if [[ "$line" == "worktree "* ]]; then
                wt_path="${line#worktree }"
                wt_branch=""
            elif [[ "$line" == "branch "* ]]; then
                wt_branch="${line#branch refs/heads/}"
            elif [[ -z "$line" ]]; then
                if [[ "$wt_path" != "$dir" && -n "$wt_branch" ]]; then
                    entries+=("${repo_name}|${wt_branch}|${wt_path}|none|0")
                fi
            fi
        done < <(git -C "$dir" worktree list --porcelain 2>/dev/null; echo)
    done

    rm -rf "$tmpdir"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh tests/test-start-claude.sh`
Expected: All tests PASS (existing + 4 new)

- [ ] **Step 5: Commit**

```bash
git add scripts/runtime/start-claude.sh tests/test-start-claude.sh
git commit -m "Add discover_entries with inline find and parallel git"
```

---

### Task 2: Session Matching

**Files:**
- Modify: `scripts/runtime/start-claude.sh` (add `get_sessions()` and `match_sessions()`)
- Modify: `tests/test-start-claude.sh` (add session tests)

- [ ] **Step 1: Write failing tests**

Add to `tests/test-start-claude.sh`:

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run.sh tests/test-start-claude.sh`
Expected: 5 new tests FAIL (get_sessions/match_sessions not found)

- [ ] **Step 3: Implement `get_sessions()` and `match_sessions()`**

Add after `discover_entries()` in `scripts/runtime/start-claude.sh`:

```bash
# --- Session matching ---
get_sessions() {
    session_names=()
    session_states=()
    session_activities=()

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name attached activity
        read -r name attached activity <<< "$line"

        # Only track claude-* sessions
        [[ "$name" == claude-* ]] || continue

        session_names+=("$name")
        if [[ "$attached" -gt 0 ]]; then
            session_states+=("attached")
        else
            session_states+=("idle")
        fi
        session_activities+=("$activity")
    done < <(tmux list-sessions -F '#{session_name} #{session_attached} #{session_activity}' 2>/dev/null || true)
}

match_sessions() {
    orphaned_sessions=()

    for si in "${!session_names[@]}"; do
        local sname="${session_names[$si]}"
        local sstate="${session_states[$si]}"
        local sactivity="${session_activities[$si]}"
        local found=false

        for ei in "${!entries[@]}"; do
            IFS='|' read -r repo_name branch path _state _activity <<< "${entries[$ei]}"
            local dirname
            dirname=$(basename "$path" | tr './:' '-')
            local expected_session="claude-${dirname}"

            if [[ "$sname" == "$expected_session" ]]; then
                entries[$ei]="${repo_name}|${branch}|${path}|${sstate}|${sactivity}"
                found=true
                break
            fi
        done

        if [[ "$found" == false ]]; then
            orphaned_sessions+=("${sname}|${sstate}|${sactivity}")
        fi
    done
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh tests/test-start-claude.sh`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/runtime/start-claude.sh tests/test-start-claude.sh
git commit -m "Add session matching with orphaned session detection"
```

---

### Task 3: Smart Default

**Files:**
- Modify: `scripts/runtime/start-claude.sh` (add `compute_default()`)
- Modify: `tests/test-start-claude.sh` (add default tests)

- [ ] **Step 1: Write failing tests**

Add to `tests/test-start-claude.sh`:

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run.sh tests/test-start-claude.sh`
Expected: 5 new tests FAIL

- [ ] **Step 3: Implement `compute_default()`**

Add after `match_sessions()` in `scripts/runtime/start-claude.sh`:

```bash
# --- Smart default ---
compute_default() {
    default_idx=0

    [[ ${#entries[@]} -eq 0 ]] && return

    # Find the most recently active idle session
    local best_idx=-1
    local best_activity=0

    for i in "${!entries[@]}"; do
        IFS='|' read -r _ _ _ state activity <<< "${entries[$i]}"
        if [[ "$state" == "idle" && "$activity" -gt "$best_activity" ]]; then
            best_activity="$activity"
            best_idx=$i
        fi
    done

    if [[ $best_idx -ge 0 ]]; then
        default_idx=$best_idx
    fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh tests/test-start-claude.sh`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/runtime/start-claude.sh tests/test-start-claude.sh
git commit -m "Add smart default targeting most recent idle session"
```

---

### Task 4: Compact Menu Rendering

**Files:**
- Modify: `scripts/runtime/start-claude.sh` (add `show_menu()`)
- Modify: `tests/test-start-claude.sh` (add menu output tests)

- [ ] **Step 1: Write failing tests**

Add to `tests/test-start-claude.sh`:

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run.sh tests/test-start-claude.sh`
Expected: 7 new tests FAIL

- [ ] **Step 3: Implement `show_menu()`**

Add after `compute_default()` in `scripts/runtime/start-claude.sh`:

```bash
# --- Compact menu rendering ---
show_menu() {
    local prev_repo=""
    local idx=1

    echo ""

    if [[ ${#entries[@]} -eq 0 ]]; then
        echo "  (no repos — press m to clone)"
    else
        for i in "${!entries[@]}"; do
            IFS='|' read -r repo_name branch path state activity <<< "${entries[$i]}"

            # Print repo header when repo changes
            if [[ "$repo_name" != "$prev_repo" ]]; then
                [[ -n "$prev_repo" ]] && echo ""
                echo "  ${repo_name}"
                prev_repo="$repo_name"
            fi

            # Branch line with optional session marker
            local marker=""
            if [[ "$state" == "idle" ]]; then
                marker="  ← active (idle)"
            elif [[ "$state" == "attached" ]]; then
                marker="  ← active (attached)"
            fi

            echo "  [${idx}] ${branch}${marker}"
            ((idx++))
        done
    fi

    # Orphaned sessions
    if [[ ${#orphaned_sessions[@]} -gt 0 ]]; then
        echo ""
        echo "  sessions"
        for os in "${orphaned_sessions[@]}"; do
            IFS='|' read -r sname sstate _ <<< "$os"
            local omarker=""
            [[ "$sstate" == "attached" ]] && omarker="  ← active (attached)"
            [[ "$sstate" == "idle" ]] && omarker="  ← active (idle)"
            echo "  [${idx}] ${sname}${omarker}"
            ((idx++))
        done
    fi

    # Footer
    echo ""
    if [[ ${#entries[@]} -eq 0 ]]; then
        echo "  Enter=m  m=manage  h=host  c=container"
    else
        local default_display=$(( default_idx + 1 ))
        echo "  Enter=${default_display}  m=manage  h=host  c=container"
    fi
    echo ""
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh tests/test-start-claude.sh`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/runtime/start-claude.sh tests/test-start-claude.sh
git commit -m "Add compact show_menu with grouped repos and inline markers"
```

---

### Task 5: Main Loop Rewrite

Replace the two-layer main loop with flat navigation, background container check, and unified selection. Remove old functions.

**Files:**
- Modify: `scripts/runtime/start-claude.sh` (rewrite main section, add `select_entry` + container helpers, remove old functions)

- [ ] **Step 1: Add `ensure_container_bg()` and `wait_for_container()`**

Add after the config/helper section, before `discover_entries()`:

```bash
# --- Background container check ---
container_pid=""

ensure_container_bg() {
    (
        if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            exit 0
        else
            cd "$COMPOSE_DIR" && "${COMPOSE_CMD[@]}" up -d >/dev/null 2>&1
            sleep 2
            "${COMPOSE_CMD[@]}" exec -u root dev bash -c \
                "chown -R dev:dev /home/dev/projects" 2>/dev/null || true
        fi
    ) &
    container_pid=$!
}

wait_for_container() {
    if [[ -n "$container_pid" ]]; then
        if ! wait "$container_pid" 2>/dev/null; then
            echo "  Container failed to start."
            return 1
        fi
        container_pid=""
    fi
}
```

- [ ] **Step 2: Add `select_entry()`**

Add after `show_menu()`:

```bash
# --- Entry selection (unified: re-attach or new session) ---
select_entry() {
    local idx="$1"

    if [[ $idx -lt ${#entries[@]} ]]; then
        IFS='|' read -r _ _ path state _ <<< "${entries[$idx]}"
        local session_name
        session_name="claude-$(basename "$path" | tr './:' '-')"

        if [[ "$state" == "idle" || "$state" == "attached" ]]; then
            echo "  -> $session_name"
            echo ""
            exec tmux attach-session -t "$session_name"
        else
            wait_for_container || return 1
            launch "$path" || return 1
        fi
    else
        # Orphaned session
        local oi=$(( idx - ${#entries[@]} ))
        IFS='|' read -r sname _ _ <<< "${orphaned_sessions[$oi]}"
        echo "  -> $sname"
        echo ""
        exec tmux attach-session -t "$sname"
    fi
}
```

- [ ] **Step 3: Modify `launch()` to remove the old container check**

The existing `launch()` function checks `docker ps` inline. Remove the container start block since `wait_for_container` now handles it. The function should be:

```bash
launch() {
    local selected="$1"
    local container_path
    container_path=$(to_container_path "$selected")

    session_name="claude-$(basename "$selected" | tr './:' '-')"

    if ! check_session_limit "$session_name"; then
        return 1
    fi

    echo "  -> $session_name"
    echo ""

    exec tmux new-session -A -s "$session_name" \
        "docker exec -it -e CLAUDE_MOBILE=\"${CLAUDE_MOBILE:-}\" -w '$container_path' ${CONTAINER_NAME} bash -lc 'exec claude'"
}
```

(This is the same as the existing `launch()` — it already doesn't have a container check. No change needed here.)

- [ ] **Step 4: Replace the main section**

Delete everything from the `# --- Discover repos and worktrees ---` comment through the end of file (the old `discover`, `get_worktrees`, `show_repos`, `show_branches`, `reattach_session`, and the two-layer main loop). Replace with:

```bash
# --- Main ---
ensure_container_bg
discover_entries
get_sessions
match_sessions
compute_default

while true; do
    show_menu

    read -r -p "  > " choice || true

    if [[ "$choice" == "m" ]]; then
        wait_for_container || continue
        launch_host "$COMPOSE_DIR" || continue
    elif [[ "$choice" == "h" ]]; then
        launch_shell_host
    elif [[ "$choice" == "c" ]]; then
        wait_for_container || continue
        launch_shell_container
    elif [[ -z "$choice" ]]; then
        # Smart default
        if [[ ${#entries[@]} -eq 0 ]]; then
            wait_for_container || continue
            launch_host "$COMPOSE_DIR" || continue
        else
            select_entry "$default_idx" || continue
        fi
    elif [[ "$choice" =~ ^[0-9]+$ ]]; then
        idx=$(( choice - 1 ))
        total=$(( ${#entries[@]} + ${#orphaned_sessions[@]} ))
        if [[ $idx -ge 0 && $idx -lt $total ]]; then
            select_entry "$idx" || continue
        fi
    fi
done
```

- [ ] **Step 5: Remove old functions that are no longer called**

Delete these functions from the script (they are replaced by the new code above):
- `discover()` (the old version that called `worktree-helper.sh list-repos`)
- `get_worktrees()` (Layer 2 is gone)
- `show_repos()` (replaced by `show_menu()`)
- `show_branches()` (Layer 2 is gone)
- `reattach_session()` (replaced by `select_entry()`)

Also remove the old variable declarations that referenced worktree-helper:
```bash
WORKTREE_HELPER="$COMPOSE_DIR/scripts/runtime/worktree-helper.sh"
```

And the old container-start block at the top (lines 96-102 of the original) — this is now handled by `ensure_container_bg()`.

- [ ] **Step 6: Run tests**

Run: `bash tests/run.sh tests/test-start-claude.sh`
Expected: All new tests PASS. Some existing tests may need updating (handled in Task 6).

- [ ] **Step 7: Commit**

```bash
git add scripts/runtime/start-claude.sh
git commit -m "Rewrite main loop: flat navigation, background container, smart default"
```

---

### Task 6: Update Tests and Verify

Update existing tests that reference removed functions, run the full suite, and do manual verification.

**Files:**
- Modify: `tests/test-start-claude.sh` (update `_source_functions`, remove/update stale tests)

- [ ] **Step 1: Update `_source_functions` for removed/changed functions**

The existing `_source_functions` extracts `discover()` which no longer exists. Update it to only extract functions that still exist:

```bash
_source_functions() {
    export COMPOSE_DIR="$HOME/dev-env"
    export CONTAINER_NAME="claude-dev"
    export CONTAINER_PROJECTS="/home/dev/projects"

    eval "$(sed -n '/^count_sessions()/,/^}/p' "$START_SCRIPT")"
    eval "$(sed -n '/^get_max_sessions()/,/^}/p' "$START_SCRIPT")"
    eval "$(sed -n '/^check_session_limit()/,/^}/p' "$START_SCRIPT")"
    eval "$(sed -n '/^to_container_path()/,/^}/p' "$START_SCRIPT")"
}
```

(Removed the `discover` extraction line.)

- [ ] **Step 2: Update `test_discover_finds_repos` to use new function**

The old `test_discover_finds_repos` tests the removed `discover()`. Delete it — its functionality is now covered by `test_discover_entries_finds_repos` from Task 1.

Remove this test function:
```bash
test_discover_finds_repos
```

- [ ] **Step 3: Run full test suite**

Run: `bash tests/run.sh`
Expected: All test files PASS

- [ ] **Step 4: Manual verification**

Verify the menu renders correctly by examining the script structure:

Run: `bash -n scripts/runtime/start-claude.sh` (syntax check)
Expected: No errors

Run: `head -5 scripts/runtime/start-claude.sh` (verify shebang and header)
Expected: `#!/bin/bash` and the script header comment

- [ ] **Step 5: Commit**

```bash
git add tests/test-start-claude.sh
git commit -m "Update tests for login menu rewrite"
```

- [ ] **Step 6: Run full test suite one final time**

Run: `bash tests/run.sh`
Expected: All test files PASS with 0 failures
