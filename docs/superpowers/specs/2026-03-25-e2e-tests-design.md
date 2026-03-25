# E2E Test Suite Design

## Overview

A plain-bash e2e test suite for the runtime scripts (scope A+B: shell-testable + integration scripts). No external test frameworks. Runs locally via `bash tests/run.sh` and in CI on PRs/push.

## Scope

**In scope (testable without Claude auth):**

| Script | What we test |
|--------|-------------|
| `worktree-helper.sh` | list-repos, list-worktrees, create, remove, cleanup (dry-run, force, stale detection) |
| `ssh-login.sh` | Guard clauses (tmux, interactive, NO_CLAUDE, SSH_CONNECTION), onboarding gate, update notification, dispatch to onboarding vs start-claude |
| `start-claude.sh` | Session limit calculation, MAX_SESSIONS override, discover(), path conversion helpers, container startup logic |
| `update.sh` | Git pull, pending file creation/format, idempotency (no-op when up to date) |
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
- `test_list_repos_skips_claude_worktrees` -- `.claude/worktrees/` filtered out
- `test_list_repos_distinguishes_repo_vs_worktree` -- REPO vs WORKTREE prefix
- `test_list_worktrees_returns_branches` -- lists worktrees with branch names
- `test_list_worktrees_skips_detached_head` -- detached HEAD excluded
- `test_create_worktree` -- creates at expected path with naming convention
- `test_remove_worktree` -- removes and prunes
- `test_cleanup_dry_run` -- reports without deleting
- `test_cleanup_removes_merged` -- merged worktrees removed
- `test_cleanup_force_removes_stale` -- stale (>7 days) removed with --force
- `test_cleanup_keeps_recent` -- worktrees with recent commits kept

### test-ssh-login.sh

- `test_skips_in_tmux` -- exits early when TMUX set
- `test_skips_non_interactive` -- exits when shell not interactive
- `test_skips_no_claude` -- exits when NO_CLAUDE=1
- `test_skips_no_ssh` -- exits when SSH_CONNECTION unset
- `test_shows_update_pending` -- prints notification when ~/.update-pending exists
- `test_execs_onboarding_when_not_initialized` -- calls onboarding.sh when ~/.workspace-initialized missing
- `test_execs_start_claude_when_initialized` -- calls start-claude.sh when initialized

Mock onboarding.sh and start-claude.sh as stubs that write to a marker file so we can verify which was called.

### test-start-claude.sh

- `test_count_sessions_zero` -- no tmux sessions returns 0
- `test_count_sessions_counts_claude_prefix` -- counts only claude-* sessions
- `test_max_sessions_env_override` -- MAX_SESSIONS env respected
- `test_max_sessions_calculated` -- mock meminfo/nproc, verify formula
- `test_max_sessions_minimum_one` -- never returns 0
- `test_discover_finds_repos` -- calls worktree-helper, formats entries
- `test_to_container_path` -- ~/projects/foo -> /home/dev/projects/foo
- `test_to_host_path` -- /home/dev/projects/foo -> ~/projects/foo

### test-update.sh

- `test_creates_pending_on_new_commits` -- pending file written with correct format
- `test_pending_contains_shas` -- before/after SHAs present
- `test_pending_contains_log` -- commit messages included
- `test_noop_when_up_to_date` -- no pending file created
- `test_handles_ff_only_failure` -- exits cleanly on divergent history

Uses real git repos: create a bare remote, clone it, push a commit to the remote, then run update.sh on the clone.

### test-tmux-status.sh

- `test_format_zero_sessions` -- shows 0/N
- `test_format_multiple_sessions` -- shows correct count
- `test_respects_max_sessions_env` -- uses MAX_SESSIONS override

Mock tmux list-sessions, nproc, and /proc/meminfo.

### test-statusline.sh

- `test_parses_model_id` -- extracts model name from JSON
- `test_color_green_above_30` -- >30% remaining = green
- `test_color_yellow_10_to_30` -- 10-30% = yellow
- `test_color_red_below_10` -- <10% = red
- `test_reads_effort_from_settings` -- picks up effort level
- `test_handles_empty_input` -- no crash on empty/missing JSON

Pipe canned JSON to the script via stdin.

## Mocking Strategy

- **Mock binaries**: `mock_binary docker "claude-dev"` creates `$TEST_DIR/bin/docker` that echoes canned output and logs invocations. PATH is prepended.
- **Real git**: worktree and update tests use actual git operations in temp dirs.
- **Source functions**: where possible, source the script and call functions directly (discover, count_sessions, to_container_path) rather than running the full script.
- **Subshell exec testing**: for scripts that `exec` (ssh-login.sh), run in a subshell and check which mock got called via marker files.
- **Mock /proc/meminfo**: create a fake file, override the path in the function or redirect.

## CI Workflow

`.github/workflows/e2e-tests.yml`:

- **Trigger**: PR and push to main
- **Path filter**: `scripts/**`, `tests/**`, `Dockerfile`, `docker-compose*.yml`
- **Runner**: ubuntu-latest
- **Steps**: checkout, install deps (git, tmux, jq, docker already on runner), `bash tests/run.sh`
- **No auth needed**: all external tools are mocked
