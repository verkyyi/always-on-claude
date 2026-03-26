# Host Shell Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add host shell, container shell, and session reattach options to the SSH login workspace picker menu.

**Architecture:** Modify the `show_repos` display function to include `[aN]` selectors for active sessions, `[h]`/`[c]` shell options, and widen the session filter from `claude-*` to include `shell-*`. Switch input from `read -n 1` to `read -r` for multi-character input (`a1`, `a2`, etc.). Apply equivalent changes to the portable variant.

**Tech Stack:** Bash, tmux

**Spec:** `docs/superpowers/specs/2026-03-26-host-shell-menu-design.md`

---

### Task 1: Update `show_repos` session display in `start-claude.sh`

Update the active sessions section to show both `claude-*` and `shell-*` sessions with `[aN]` selectors for reattach, and add `[h]`/`[c]` options to the menu.

**Files:**
- Modify: `scripts/runtime/start-claude.sh:128-159` (`show_repos` function)

- [ ] **Step 1: Update session filter and add `[aN]` selectors**

Replace the `show_repos` function (lines 128-159) with:

```bash
# --- Layer 1: Pick a repo ---
show_repos() {
    # Collect active claude-* and shell-* tmux sessions
    # Note: all_sessions is intentionally global — read by reattach_session()
    all_sessions=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && all_sessions+=("$line")
    done < <(tmux list-sessions -F '#{session_name} #{?session_attached,(attached),(idle)}' 2>/dev/null \
        | grep -E '^(claude-|shell-)' || true)

    if [[ ${#all_sessions[@]} -gt 0 ]]; then
        echo ""
        echo "  === Active sessions ($(count_sessions)/$(get_max_sessions)) ==="
        local ai=1
        for s in "${all_sessions[@]}"; do
            echo "  [a${ai}] $s"
            ((ai++))
        done
    fi

    echo ""
    echo "  === Repositories ==="
    local i=1
    for item in "${repos[@]+"${repos[@]}"}"; do
        IFS='|' read -r path branch <<< "$item"
        local short_path="${path#$HOME/}"
        echo "  [$i] ${short_path} (${branch})"
        ((i++))
    done

    if [[ ${#repos[@]} -eq 0 ]]; then
        echo "  (no repos found — press [m] to clone your first repo)"
    fi

    echo "  [m] Manage workspaces"
    echo "  [h] Host shell"
    echo "  [c] Container shell"
    echo ""
}
```

Key changes:
- Filter now uses `grep -E '^(claude-|shell-)'` to include shell sessions
- Sessions stored in `all_sessions` array (needed for `[aN]` index lookup)
- Each session gets an `[a1]`, `[a2]`, etc. selector
- Added `[h]` and `[c]` menu items
- Removed the `Clone repos, create worktrees, and more` subtitle line for `[m]` to keep menu compact

- [ ] **Step 2: Verify the script is syntactically valid**

Run: `bash -n scripts/runtime/start-claude.sh`
Expected: no output (valid syntax)

- [ ] **Step 3: Commit**

```bash
git add scripts/runtime/start-claude.sh
git commit -m "Update show_repos with session selectors and shell options"
```

---

### Task 2: Add shell launch functions and reattach handler in `start-claude.sh`

Add functions to launch host shell and container shell in tmux, and a function to reattach to any session by index.

**Files:**
- Modify: `scripts/runtime/start-claude.sh:200-216` (after `launch` function, before Main)

- [ ] **Step 1: Add `launch_shell_host`, `launch_shell_container`, and `reattach_session` functions**

Insert after the `launch_host` function (after line 216), before the `# --- Main ---` comment:

```bash
# --- Launch a host shell in tmux ---
launch_shell_host() {
    echo "  -> host shell"
    echo ""
    exec tmux new-session -A -s "shell-host" "bash -l"
}

# --- Launch a container shell in tmux ---
launch_shell_container() {
    echo "  -> container shell"
    echo ""
    exec tmux new-session -A -s "shell-container" \
        "docker exec -it ${CONTAINER_NAME} bash -l"
}

# --- Reattach to an active session by index ---
# Note: all_sessions is intentionally global — populated by show_repos(), read here
reattach_session() {
    local idx="$1"
    if [[ $idx -ge 1 && $idx -le ${#all_sessions[@]} ]]; then
        local session_line="${all_sessions[$((idx - 1))]}"
        local session_name="${session_line%% *}"
        echo "  -> reattach $session_name"
        echo ""
        exec tmux attach-session -t "$session_name"
    fi
    return 1
}
```

The `return 1` after the `fi` ensures invalid indices (e.g., `a99`) trigger `|| continue` in the caller instead of falling through to the worktree/Layer 2 code with an unset `selected_path`.

- [ ] **Step 2: Verify syntax**

Run: `bash -n scripts/runtime/start-claude.sh`
Expected: no output (valid syntax)

- [ ] **Step 3: Commit**

```bash
git add scripts/runtime/start-claude.sh
git commit -m "Add shell launch and session reattach functions"
```

---

### Task 3: Update Layer 1 input handling in `start-claude.sh`

Switch from `read -n 1` to `read -r` and add handling for `h`, `c`, and `aN` inputs.

**Files:**
- Modify: `scripts/runtime/start-claude.sh:221-242` (Layer 1 loop)

- [ ] **Step 1: Replace the Layer 1 input handling**

Replace lines 222-242 (the `while true` Layer 1 loop body) with:

```bash
while true; do
    show_repos

    read -r -p "  > " choice || true

    if [[ "$choice" == "m" ]]; then
        # Launch Claude on the host for workspace management and updates
        launch_host "$COMPOSE_DIR" || continue
    elif [[ "$choice" == "h" ]]; then
        launch_shell_host
    elif [[ "$choice" == "c" ]]; then
        launch_shell_container
    elif [[ "$choice" =~ ^a([0-9]+)$ ]]; then
        reattach_session "${BASH_REMATCH[1]}" || continue
    elif [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#repos[@]}" ]]; then
        IFS='|' read -r selected_path selected_branch <<< "${repos[$((choice - 1))]}"
    elif [[ -z "$choice" ]]; then
        # Default: first repo, or home if none
        if [[ ${#repos[@]} -gt 0 ]]; then
            IFS='|' read -r selected_path selected_branch <<< "${repos[0]}"
        else
            launch "$HOME/projects" || continue
        fi
    else
        continue
    fi
```

Key changes:
- `read -n 1` becomes `read -r`
- Added `h`, `c`, and `aN` regex match branches
- Removed `$'\n'` check (not needed with `read -r` — empty input is just empty string)

- [ ] **Step 2: Update Layer 2 input handling**

Replace the Layer 2 loop (lines 253-268) with:

```bash
    # Layer 2 loop
    while true; do
        show_branches "$selected_path" "$selected_branch"

        read -r -p "  > " choice2 || true

        if [[ "$choice2" == "b" ]]; then
            break  # Back to Layer 1
        elif [[ "$choice2" == "1" || -z "$choice2" ]]; then
            # Main repo
            launch "$selected_path" || continue
        elif [[ "$choice2" =~ ^[0-9]+$ && "$choice2" -ge 2 && "$choice2" -le $(( ${#worktrees[@]} + 1 )) ]]; then
            IFS='|' read -r wt_selected _ <<< "${worktrees[$((choice2 - 2))]}"
            launch "$wt_selected" || continue
        fi
    done
```

Key change: `read -n 1` becomes `read -r`, removed `$'\n'` check.

- [ ] **Step 3: Verify syntax**

Run: `bash -n scripts/runtime/start-claude.sh`
Expected: no output (valid syntax)

- [ ] **Step 4: Commit**

```bash
git add scripts/runtime/start-claude.sh
git commit -m "Switch to Enter-terminated input, add h/c/aN handlers"
```

---

### Task 4: Update `start-claude-portable.sh`

Apply equivalent changes to portable mode: updated session display with `[aN]` selectors, `[h]` shell option (no `[c]`), and Enter-terminated input.

**Files:**
- Modify: `scripts/portable/start-claude-portable.sh:86-117` (`show_repos`)
- Modify: `scripts/portable/start-claude-portable.sh:140-166` (launch functions)
- Modify: `scripts/portable/start-claude-portable.sh:173-220` (main loops)

- [ ] **Step 1: Update `show_repos` in portable mode**

Replace the `show_repos` function (lines 86-117) with:

```bash
show_repos() {
    # Collect active claude-* and shell-* tmux sessions
    # Note: all_sessions is intentionally global — read by reattach_session()
    all_sessions=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && all_sessions+=("$line")
    done < <(tmux list-sessions -F '#{session_name} #{?session_attached,(attached),(idle)}' 2>/dev/null \
        | grep -E '^(claude-|shell-)' || true)

    if [[ ${#all_sessions[@]} -gt 0 ]]; then
        echo ""
        echo "  === Active sessions ==="
        local ai=1
        for s in "${all_sessions[@]}"; do
            echo "  [a${ai}] $s"
            ((ai++))
        done
    fi

    echo ""
    echo "  === Repositories ==="
    local i=1
    for item in "${repos[@]+"${repos[@]}"}"; do
        IFS='|' read -r path branch <<< "$item"
        local short_path="${path#"$HOME"/}"
        echo "  [$i] ${short_path} (${branch})"
        ((i++))
    done

    if [[ ${#repos[@]} -eq 0 ]]; then
        echo "  (no repos found — press [m] to clone your first repo)"
    fi

    echo "  [m] Manage workspaces"
    echo "  [h] Shell"
    echo ""
}
```

- [ ] **Step 2: Add `launch_shell` and `reattach_session` functions**

Insert after the `launch_manager` function (after line 166), before `# --- Main ---`:

```bash
# --- Launch a shell in tmux ---
launch_shell() {
    echo "  -> shell"
    echo ""
    exec tmux new-session -A -s "shell-local" "bash -l"
}

# --- Reattach to an active session by index ---
# Note: all_sessions is intentionally global — populated by show_repos(), read here
reattach_session() {
    local idx="$1"
    if [[ $idx -ge 1 && $idx -le ${#all_sessions[@]} ]]; then
        local session_line="${all_sessions[$((idx - 1))]}"
        local session_name="${session_line%% *}"
        echo "  -> reattach $session_name"
        echo ""
        exec tmux attach-session -t "$session_name"
    fi
    return 1
}
```

- [ ] **Step 3: Update Layer 1 input handling**

Replace the Layer 1 loop (lines 174-193) with:

```bash
while true; do
    show_repos

    read -r -p "  > " choice || true

    if [[ "$choice" == "m" ]]; then
        launch_manager "$DEV_ENV"
    elif [[ "$choice" == "h" ]]; then
        launch_shell
    elif [[ "$choice" =~ ^a([0-9]+)$ ]]; then
        reattach_session "${BASH_REMATCH[1]}" || continue
    elif [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#repos[@]}" ]]; then
        IFS='|' read -r selected_path selected_branch <<< "${repos[$((choice - 1))]}"
    elif [[ -z "$choice" ]]; then
        # Default: first repo, or projects dir if none
        if [[ ${#repos[@]} -gt 0 ]]; then
            IFS='|' read -r selected_path selected_branch <<< "${repos[0]}"
        else
            launch "$HOME/projects"
        fi
    else
        continue
    fi
```

- [ ] **Step 4: Update Layer 2 input handling**

Replace the Layer 2 loop (lines 204-219) with:

```bash
    # Layer 2 loop
    while true; do
        show_branches "$selected_path" "$selected_branch"

        read -r -p "  > " choice2 || true

        if [[ "$choice2" == "b" ]]; then
            break  # Back to Layer 1
        elif [[ "$choice2" == "1" || -z "$choice2" ]]; then
            # Main repo
            launch "$selected_path"
        elif [[ "$choice2" =~ ^[0-9]+$ && "$choice2" -ge 2 && "$choice2" -le $(( ${#worktrees[@]} + 1 )) ]]; then
            IFS='|' read -r wt_selected _ <<< "${worktrees[$((choice2 - 2))]}"
            launch "$wt_selected"
        fi
    done
```

- [ ] **Step 5: Verify syntax**

Run: `bash -n scripts/portable/start-claude-portable.sh`
Expected: no output (valid syntax)

- [ ] **Step 6: Commit**

```bash
git add scripts/portable/start-claude-portable.sh
git commit -m "Add shell option and session reattach to portable menu"
```

---

### Task 5: Update CLAUDE.md menu description

Update the project documentation to reflect the new menu options.

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the menu description**

On line 71 of `CLAUDE.md`, replace:

```
  ssh-login.sh             — Menu on SSH login: [1] Claude Code, [2] container bash, [3] host shell
```

with:

```
  ssh-login.sh             — Menu on SSH login: numbered repos, [m] manage, [h] host shell, [c] container shell, [aN] reattach
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Update CLAUDE.md menu description for new options"
```

---

### Task 6: Manual smoke test

No automated test suite exists for this project. Test manually.

- [ ] **Step 1: Verify both scripts pass syntax check**

```bash
bash -n scripts/runtime/start-claude.sh
bash -n scripts/portable/start-claude-portable.sh
```

Expected: no output from either command.

- [ ] **Step 2: Test the menu renders correctly**

SSH into the workspace (or run `bash scripts/runtime/start-claude.sh` directly) and verify:
- Active sessions section shows `[aN]` selectors
- `[h]` Host shell and `[c]` Container shell appear in the menu
- Input now requires Enter key after typing

- [ ] **Step 3: Test each new option**

- Type `h` + Enter → should open a host bash shell in tmux session `shell-host`
- Detach (Ctrl-b d), re-run menu → `shell-host` should appear in active sessions
- Type `c` + Enter → should open container bash in tmux session `shell-container`
- Type the `aN` selector for an active session → should reattach to it
- Type a repo number + Enter → should launch Claude as before
