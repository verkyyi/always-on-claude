# Login Menu Optimization

Redesign the SSH login workspace picker (`scripts/runtime/start-claude.sh`) for speed, visual clarity, and mobile readability while keeping the number-based input model.

## Goals

- Faster time-to-Claude for the common case (one repo, re-attach to existing session)
- Compact, scannable layout that works well on narrow mobile terminals (Termius, Blink)
- Eliminate cognitive overhead of separate session vs repo selection
- Reduce startup latency from discovery and container checks

## Non-goals

- TUI/interactive libraries (fzf, gum) — worse on mobile keyboards
- Repo discovery caching — staleness risk not worth it for < 10 repos
- Changing the interaction model — number input + Enter is already mobile-optimal

## Design

### 1. Compact Menu Layout

Replace the current verbose layout with a compact, grouped display.

**Before:**
```
  === Active sessions (1/5) ===
  [a1] claude-always-on-claude (idle)

  === Repositories ===
  [1] projects/always-on-claude (main)
  [2] projects/my-app (feature/auth)
  [m] Manage workspaces
  [h] Host shell
  [c] Container shell
```

**After:**
```
  always-on-claude
  [1] main  ← active (idle)

  my-app
  [2] feature/auth

  Enter=1  m=manage  h=host  c=container
```

Changes:
- Repo name is the section header (not a numbered line)
- `projects/` prefix stripped — always the same, no information value
- Branch name is the selectable item, not the full path
- Active session marker (`← active`) merged into its branch line
- Utility options (`m`, `h`, `c`) collapsed into a single compact footer line
- Session counter (`1/5`) hidden from display — still enforced when limit is hit

### 2. Smart Default

The Enter key (empty input) selects intelligently:

- **Active idle session exists** → re-attach to the most recently used idle session
- **No active session** → launch the first repo (current behavior)
- **Multiple idle sessions** → pick the most recently used one

The footer dynamically shows which number Enter targets: `Enter=1` or `Enter=3`.

**Determining "most recent":** Use tmux `session_activity` timestamp to rank idle sessions. Falls back to first repo if no sessions exist.

### 3. Unified Session + Repo List

Eliminate the separate "Active sessions" section and the `a1`/`a2` index scheme.

Active sessions are shown inline as markers on their corresponding branch lines. Selecting a branch that has an active session re-attaches instead of creating a new one. This is the same behavior as the current `a1` shortcut, but without a separate mental model.

Session states:
- `← active (idle)` — session exists, no one attached. Selecting re-attaches.
- `← active (attached)` — another SSH connection has it open. Selecting still works (tmux shared attach). Marker informs the user.

**Session-to-branch matching:** Sessions are named `claude-<dirname>` (via `basename "$path" | tr './:' '-'`). Discovery builds a map of dirname → path for all repos and worktrees. A tmux session matches a branch if its session name matches the dirname of that branch's directory. Sessions that don't match any discovered directory are orphaned.

If a `claude-*` tmux session exists but doesn't match any discovered repo (orphaned session from a deleted repo), list it at the bottom under a `sessions` header so it's still accessible.

### 4. Flat Navigation (No Layer 2)

Currently, selecting a repo with worktrees drops into a second menu to pick a branch. With the new layout, all branches (main repo + worktrees) are visible as numbered lines under their repo header.

**Before (two layers):**
```
  Layer 1: [1] always-on-claude (main)
  → Layer 2: [1] main (repo)  [2] fix/login-menu (worktree)  [b] Back
```

**After (flat):**
```
  always-on-claude
  [1] main  ← active (idle)
  [2] fix/login-menu
```

Layer 2 loop, `show_branches()`, and the `[b] Back` option are removed entirely. Every selectable item is a branch — whether it lives in the main repo or a worktree directory. The `(repo)` vs `(worktree)` labels are dropped; users care about the branch name, not the git mechanism.

### 5. Startup Speed

Three optimizations to reduce time from SSH to rendered menu:

**5a. Parallel git queries**

Current `cmd_list_repos()` in `worktree-helper.sh` runs `git branch --show-current` sequentially for each discovered `.git` entry. Change to:
- Run `find` to collect all `.git` paths
- Spawn `git branch --show-current` for each path as background jobs
- `wait` and collect results

**5b. Background container check**

The `docker ps` check (line 96 of `start-claude.sh`) currently blocks before any menu rendering. Change to:
- Start the container check as a background job at the top of the script
- Render the menu immediately from discovery results
- When the user makes a selection, `wait` on the container check before launching

If the container needs starting, show `Starting container...` at launch time, not before the menu.

**5c. Inline discovery**

Currently `discover()` calls `bash "$WORKTREE_HELPER" list-repos` as a subprocess, which forks a new shell, re-sources config, and runs `find`. Inline the discovery logic directly into `start-claude.sh` to eliminate the subprocess overhead.

The `worktree-helper.sh` script remains for its other subcommands (`create`, `remove`, `cleanup`, `list-worktrees`). Only `list-repos` gets inlined, and `list-worktrees` is no longer called from `start-claude.sh` (Layer 2 is gone, worktrees are discovered inline alongside repos).

### 6. Mobile Considerations

The redesigned layout is already compact enough for narrow terminals. No separate mobile layout is needed. The `CLAUDE_MOBILE=1` flag continues to be set by `ssh-login.sh` and passed through to Claude Code sessions — the menu itself doesn't branch on it.

## Files Changed

| File | Change |
|------|--------|
| `scripts/runtime/start-claude.sh` | Full rewrite of menu rendering, discovery inlining, background container check, flat navigation, smart default |
| `scripts/runtime/worktree-helper.sh` | No changes — still used for `create`, `remove`, `cleanup` subcommands |
| `scripts/runtime/ssh-login.sh` | No changes |
| `scripts/runtime/manager-prompt.txt` | No changes |

## Edge Cases

- **No repos:** Show `(no repos — press m to clone)` with footer. Enter targets `m`.
- **Orphaned tmux sessions:** Sessions whose repo was deleted. Listed under a `sessions` header at the bottom with their tmux session name.
- **Session limit hit:** Show limit message inline when the user selects a new branch (current behavior), not preemptively in the menu.
- **Container not running:** Background check starts it. If user selects before it's ready, show `Starting container...` and wait.
- **All sessions attached:** Still selectable (tmux shared attach). `(attached)` marker warns the user.
