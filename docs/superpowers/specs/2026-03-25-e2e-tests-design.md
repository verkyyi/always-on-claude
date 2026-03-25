# E2E Test Suite Design

## Overview

A plain-bash e2e test suite for the runtime scripts (scope A+B: shell-testable + integration scripts). No external test frameworks. Runs locally via `bash tests/run.sh` and in CI on PRs/push.

## Scope

**In scope (testable without Claude auth):**

| Script | What we test |
|--------|-------------|
| `worktree-helper.sh` | list-repos, list-worktrees, create, remove, cleanup (dry-run, force, stale detection) |
| `ssh-login.sh` | Guard clauses (tmux, interactive, NO_CLAUDE, SSH_CONNECTION), onboarding gate, update notification, dispatch to onboarding vs start-claude |
| `start-claude.sh` | Session limit calculation, MAX_SESSIONS override, discover(), path conversion, container startup logic |
| `update.sh` | Git pull, pending file creation/format, idempotency, git-guard early exit |
| `tmux-status.sh` | Session count formatting, memory/CPU calculation |
| `statusline-command.sh` | JSON parsing, model extraction, color thresholds, effort level from settings |

**Out of scope (requires Claude CLI auth):**
- `onboarding.sh` full user journey
- Claude Code launch and interactive sessions
- GitHub CLI auth flows

## File Structure

```
tests/
  test-lib.sh              -- Runner, assertions, fixtures
  run.sh                   -- Entry point: all test-*.sh or single file
  test-worktree-helper.sh  -- worktree-helper.sh tests
  test-ssh-login.sh        -- ssh-login.sh guard + dispatch tests
  test-start-claude.sh     -- session limits, discovery, path conversion
  test-update.sh           -- git pull + pending file tests
  test-tmux-status.sh      -- status bar formatting tests
  test-statusline.sh       -- Claude statusline JSON parsing tests

.github/workflows/
  e2e-tests.yml            -- CI workflow
```

## test-lib.sh

Sourced by all test files. Provides:

### Runner

- Auto-discovers `test_*` functions via `declare -F`
- Calls `setup` before each test (fresh `$TEST_DIR` via mktemp)
- Calls `teardown` after each test (rm -rf `$TEST_DIR`)
- Tracks pass/fail, prints colored summary
- Exit code 0 if all pass, 1 if any fail

### Assertions

- `assert_eq <expected> <actual> [msg]`
- `assert_neq <a> <b> [msg]`
- `assert_contains <haystack> <needle> [msg]`
- `assert_file_exists <path>`
- `assert_file_not_exists <path>`
- `assert_exit_code <expected> <command...>`
- `assert_output_contains <needle> <command...>`

### Fixtures

- `create_test_repo [name]` -- git init + initial commit in `$TEST_DIR/<name>`
- `create_test_worktree <repo> <branch>` -- git worktree add
- `mock_binary <name> [output]` -- stub in `$TEST_DIR/bin/`, prepend to PATH, records invocations to `$TEST_DIR/bin/<name>.log`

### Isolation

- `HOME=$TEST_DIR/home` per test (scripts reading `~/` don't touch real home)
- `$TEST_DIR` is a fresh mktemp dir per test

## run.sh

Entry point for local and CI use:

```
bash tests/run.sh                          # run all
bash tests/run.sh tests/test-update.sh     # run one file
```

Iterates over args (or all `tests/test-*.sh`), sources each, runs all `test_*` functions, prints grand total.

## Test Coverage by Script

### test-worktree-helper.sh

- `test_list_repos_finds_repos` -- repos at depth 1-3 discovered
- `test_list_repos_ignores_deep_repos` -- depth >3 not found
- `test_list_repos_distinguishes_repo_vs_worktree` -- REPO vs WORKTREE prefix
- `test_list_worktrees_returns_branches` -- lists worktrees with branch names
- `test_list_worktrees_skips_detached_head` -- detached HEAD excluded
- `test_create_worktree` -- creates at expected path with naming convention
- `test_create_worktree_sanitizes_branch` -- `feature/foo` becomes `feature-foo` in path
- `test_remove_worktree` -- removes and prunes
- `test_remove_rejects_non_worktree` -- exits 1 when path is not a worktree (`.git` is a dir, not a file)
- `test_cleanup_dry_run` -- reports without deleting
- `test_cleanup_removes_merged` -- merged worktrees removed
- `test_cleanup_force_removes_stale` -- stale (>7 days) removed with --force
- `test_cleanup_keeps_recent` -- worktrees with recent commits kept

### test-ssh-login.sh

Note: `ssh-login.sh` is sourced (not executed) from `.bash_profile`, so guard clauses use `return`, not `exit`. Tests run the script in a subshell via `bash -c 'source ssh-login.sh'` and check behavior via marker files and exit codes.

- `test_skips_in_tmux` -- returns early when TMUX set
- `test_skips_non_interactive` -- returns when shell not interactive
- `test_skips_no_claude` -- returns when NO_CLAUDE=1
- `test_skips_no_ssh` -- returns when SSH_CONNECTION unset
- `test_shows_update_pending` -- prints "Updates available" when ~/.update-pending exists
- `test_execs_onboarding_when_not_initialized` -- calls onboarding.sh when ~/.workspace-initialized missing
- `test_execs_start_claude_when_initialized` -- calls start-claude.sh when initialized

Mock onboarding.sh and start-claude.sh as stubs that write to a marker file so we can verify which was called.

### test-start-claude.sh

**Sourcing strategy:** `start-claude.sh` has top-level code (container check, discover call) that runs immediately on source. Tests must mock `docker` and `tmux` binaries BEFORE sourcing. The setup function creates mock binaries first, then sources the script. Functions like `count_sessions`, `get_max_sessions`, `to_container_path`, and `discover` can then be called directly.

- `test_count_sessions_zero` -- no tmux sessions returns 0
- `test_count_sessions_counts_claude_prefix` -- counts only claude-* sessions
- `test_max_sessions_env_override` -- MAX_SESSIONS env respected
- `test_max_sessions_calculated` -- formula: `min((total_mem_mb - 1024) / 650, nproc)`, floor 1. Example: 4096 MB, 2 CPUs -> `min((4096-1024)/650, 2)` = `min(4, 2)` = 2
- `test_max_sessions_minimum_one` -- low memory (1500 MB, 1 CPU) still returns 1
- `test_max_sessions_low_memory_high_cpu` -- 2048 MB, 8 CPUs -> `min(1, 8)` = 1
- `test_discover_finds_repos` -- calls worktree-helper, formats entries
- `test_to_container_path` -- ~/projects/foo -> /home/dev/projects/foo
- `test_check_session_limit_allows_reattach` -- existing session allowed even at limit

**`/proc/meminfo` injection:** The `get_max_sessions` function reads `/proc/meminfo` directly. Tests override this by creating a fake meminfo file at `$TEST_DIR/proc/meminfo` and patching the function via a wrapper that redirects the read path. Alternatively, tests can mock `awk` to return canned memory values. The simplest approach: mock `nproc` and test with `MAX_SESSIONS` env var for most cases; for the formula test, create a mock `awk` that returns the desired total memory value.

### test-update.sh

- `test_creates_pending_on_new_commits` -- pending file written with correct format
- `test_pending_contains_shas` -- before/after SHAs present
- `test_pending_contains_log` -- commit messages included
- `test_noop_when_up_to_date` -- no pending file created
- `test_handles_ff_only_failure` -- exits cleanly on divergent history
- `test_exits_when_not_git_repo` -- exits early when `$DEV_ENV/.git` doesn't exist

Uses real git repos: create a bare remote, clone it, push a commit to the remote, then run update.sh on the clone. Note: update.sh writes to `$DEV_ENV/update.log`; tests should assert or clean up this file.

### test-tmux-status.sh

- `test_format_zero_sessions` -- shows 0/N
- `test_format_multiple_sessions` -- shows correct count
- `test_respects_max_sessions_env` -- uses MAX_SESSIONS override

Mock tmux list-sessions, nproc, and /proc/meminfo.

### test-statusline.sh

- `test_parses_model_id` -- extracts model name from JSON
- `test_color_green_at_31_plus` -- >= 31% remaining = green
- `test_color_yellow_11_to_30` -- 11-30% = yellow
- `test_color_red_at_10_or_below` -- <= 10% = red
- `test_boundary_10_is_red` -- exactly 10% is red, not yellow
- `test_boundary_30_is_yellow` -- exactly 30% is yellow, not green
- `test_reads_effort_from_settings` -- picks up effort level
- `test_handles_empty_input` -- no crash on empty/missing JSON

Pipe canned JSON to the script via stdin.

## Mocking Strategy

- **Mock binaries**: `mock_binary docker "claude-dev"` creates `$TEST_DIR/bin/docker` that echoes canned output and logs invocations. PATH is prepended so mocks take precedence.
- **Real git**: worktree and update tests use actual git operations in temp dirs. Fast and realistic.
- **Source with pre-mocked PATH**: for scripts with top-level code (start-claude.sh), mock docker/tmux BEFORE sourcing so top-level code hits mocks. Then call individual functions directly.
- **Subshell sourcing**: for `ssh-login.sh` (uses `return` in sourced context), wrap in `bash -c 'source ...'` and check marker files/exit codes.
- **Mock /proc/meminfo**: for session limit formula tests, mock `awk` or `nproc` to control inputs. Use `MAX_SESSIONS` env var for most session limit tests since it bypasses the calculation entirely.
- **Marker files**: mock scripts write to `$TEST_DIR/markers/<name>` so tests can verify which script was called and with what args.

## CI Workflow

`.github/workflows/e2e-tests.yml`:

- **Trigger**: PR and push to main
- **Path filter**: `scripts/**`, `tests/**`, `Dockerfile`, `docker-compose*.yml`
- **Runner**: ubuntu-latest
- **Steps**: checkout, install deps (git, tmux, jq already on runner), `bash tests/run.sh`
- **No auth needed**: all external tools are mocked
