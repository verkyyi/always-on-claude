# Host Shell, Container Shell & Session Attach

**Issue:** #69 — Add host shell within Menu
**Date:** 2026-03-26

## Summary

Add host shell (`[h]`), container shell (`[c]`), and session reattach (`[a1]`-`[aN]`) options to the SSH login workspace picker menu. Switch input from single-keystroke to Enter-terminated to support multi-character commands.

## Changes

### 1. Input mode change

Both `start-claude.sh` and `start-claude-portable.sh` switch from `read -n 1` (single keystroke) to `read -r` (Enter-terminated) in both Layer 1 (repo picker) and Layer 2 (branch picker).

**Exception:** The `first_run_check()` function in `start-claude-portable.sh` keeps its existing `read -rn 1` — it's a binary choice where single-keystroke input is appropriate.

### 2. Menu layout (host mode — `start-claude.sh`)

```
  === Active sessions (1/3) ===
  [a1] claude-always-on-claude (idle)
  [a2] shell-host (idle)

  === Repositories ===
  [1] projects/always-on-claude (main)
  [m] Manage workspaces
  [h] Host shell
  [c] Container shell

  >
```

### 3. Menu layout (portable mode — `start-claude-portable.sh`)

```
  === Active sessions ===
  [a1] claude-my-project (idle)
  [a2] shell-local (idle)

  === Repositories ===
  [1] projects/my-project (main)
  [m] Manage workspaces
  [h] Shell

  >
```

No `[c]` in portable mode — there is no host/container distinction.

### 4. Behavior

| Key | Action | Tmux session name | Counts toward limit? |
|-----|--------|-------------------|---------------------|
| `1`-`9` | Launch Claude in repo | `claude-<repo>` | Yes |
| `a1`-`aN` | Reattach to active tmux session | (existing name) | No (already running) |
| `m` | Launch workspace manager | `claude-manager` | Yes |
| `h` | Host shell (host mode) / Shell (portable) | `shell-host` / `shell-local` | No |
| `c` | Container shell (host mode only) | `shell-container` | No |
| Enter (empty) | Default to first repo | `claude-<repo>` | Yes |
| `b` (Layer 2) | Back to Layer 1 | — | — |

### 5. Shell session details

**Host shell (`[h]` in host mode):**
- `tmux new-session -A -s shell-host "bash -l"`
- Runs on the host machine directly

**Container shell (`[c]` in host mode):**
- `tmux new-session -A -s shell-container "docker exec -it $CONTAINER_NAME bash -l"`
- Runs inside the dev container

**Shell (`[h]` in portable mode):**
- `tmux new-session -A -s shell-local "bash -l"`
- Runs directly (already inside container)

### 6. Session display

Active sessions section shows all tmux sessions (`claude-*` and `shell-*`). The existing `grep '^claude-'` filter in `show_repos` must be updated to `grep -E '^(claude-|shell-)'` to include shell sessions. Each session gets an `[aN]` selector for reattach. The count in the header (e.g., `1/3`) only counts `claude-*` sessions against the limit.

Note: `[h]`/`[c]` use `tmux new-session -A` which auto-reattaches if the session exists, so `[aN]` is redundant for shell sessions. Both paths work — `[aN]` provides a uniform reattach mechanism across all session types.

### 7. Session limit

No changes to `check_session_limit` or `get_max_sessions`. Shell sessions use `shell-*` prefix, so they are not counted by `count_sessions` which greps for `^claude-`. Reattaching via `[aN]` bypasses the limit check entirely (session already exists).

**Note:** Session limit logic only exists in host mode (`start-claude.sh`). Portable mode has no session limit enforcement — the limit discussion above applies to host mode only.

## Files modified

- `scripts/runtime/start-claude.sh` — add `[h]`, `[c]`, `[aN]` options; switch to Enter-terminated input
- `scripts/portable/start-claude-portable.sh` — add `[h]`, `[aN]` options; switch to Enter-terminated input
- `CLAUDE.md` — update menu description to reflect new options

## Out of scope

- Issue #74 (back to menu after exiting) — related but separate
- `scripts/runtime/tmux-status.sh` — has a pre-existing 1024 vs 512 memory reserve mismatch with `start-claude.sh`; worth fixing separately
- `scripts/runtime/self-update.sh` — currently only warns about `claude-*` sessions before restart; should eventually also warn about `shell-*` sessions, but not part of this change
