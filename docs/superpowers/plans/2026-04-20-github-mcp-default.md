# GitHub MCP Default Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Activate the already-installed `github` MCP plugin by default in every Claude session launched inside the dev-env container, reusing the user's existing `gh` CLI auth state.

**Architecture:** One new sourceable shell script (`gh-mcp-env.sh`) emits `GITHUB_PERSONAL_ACCESS_TOKEN=$(gh auth token)` guarded by `gh`-install + `gh auth status` checks. Installed into `~/.claude/` alongside existing per-container config. Three in-container Claude launch paths (workspace and manager in portable mode, workspace in host mode) are updated to source it before `exec claude`. A 3-line nudge goes into the global CLAUDE.md template so future agents prefer MCP tool calls over `gh` shell calls.

**Tech Stack:** Bash, tests use the repo's existing harness (`tests/test-lib.sh` + `tests/run.sh`).

**Spec:** `docs/superpowers/specs/2026-04-20-github-mcp-default-design.md`

---

## File Structure

| File | Role | Status |
|---|---|---|
| `scripts/runtime/gh-mcp-env.sh` | Guarded export — single source of truth | **create** |
| `tests/test-gh-mcp-env.sh` | Three unit tests for the guard behavior matrix | **create** |
| `scripts/deploy/install.sh` | Copy `gh-mcp-env.sh` into `~/.claude/` during provision | modify |
| `scripts/portable/start-claude-portable.sh` | Two in-container launches source the env script | modify |
| `scripts/runtime/start-claude.sh` | One in-container launch (line 372) sources the env script; host-mode manager untouched | modify |
| `scripts/runtime/claude-global.md` | 3-line nudge: prefer GitHub MCP tools over `gh` shell | modify |

---

## Task 1: Create `gh-mcp-env.sh` with TDD

**Files:**
- Create: `tests/test-gh-mcp-env.sh`
- Create: `scripts/runtime/gh-mcp-env.sh`

- [ ] **Step 1.1: Write failing tests**

Create `tests/test-gh-mcp-env.sh`:

```bash
#!/bin/bash
# Tests for scripts/runtime/gh-mcp-env.sh

GH_MCP_ENV_SCRIPT="$REPO_ROOT/scripts/runtime/gh-mcp-env.sh"

# Run the script in a subshell that:
#   - starts from a clean env (no GITHUB_PERSONAL_ACCESS_TOKEN)
#   - has PATH=$TEST_DIR/bin (no real gh leaks in)
# Prints: <token-or-UNSET> on stdout, preserves script stderr
_run_env_script() {
    (
        unset GITHUB_PERSONAL_ACCESS_TOKEN
        export PATH="$TEST_DIR/bin"
        source "$GH_MCP_ENV_SCRIPT" 2>"$TEST_DIR/stderr"
        echo "${GITHUB_PERSONAL_ACCESS_TOKEN:-UNSET}"
    )
}

_stderr() {
    cat "$TEST_DIR/stderr" 2>/dev/null || true
}

test_gh_missing_no_export_with_hint() {
    # No gh binary on PATH (TEST_DIR/bin is empty)
    local result
    result=$(_run_env_script)
    assert_eq "UNSET" "$result"
    assert_contains "$(_stderr)" "GitHub MCP inactive"
    assert_contains "$(_stderr)" "gh auth login"
}

test_gh_installed_but_unauthed_no_export_with_hint() {
    # gh exists but `gh auth status` exits non-zero
    cat > "$TEST_DIR/bin/gh" <<'MOCK'
#!/bin/bash
case "$1 $2" in
    "auth status") echo "not logged in" >&2; exit 1 ;;
    *) exit 1 ;;
esac
MOCK
    chmod +x "$TEST_DIR/bin/gh"

    local result
    result=$(_run_env_script)
    assert_eq "UNSET" "$result"
    assert_contains "$(_stderr)" "GitHub MCP inactive"
}

test_gh_authed_exports_token_silently() {
    # gh is authed and `gh auth token` prints a token
    cat > "$TEST_DIR/bin/gh" <<'MOCK'
#!/bin/bash
case "$1 $2" in
    "auth status") exit 0 ;;
    "auth token") echo "gho_testtoken123" ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$TEST_DIR/bin/gh"

    local result
    result=$(_run_env_script)
    assert_eq "gho_testtoken123" "$result"
    # Hint must NOT appear when MCP successfully activates
    local stderr
    stderr=$(_stderr)
    if [[ "$stderr" == *"GitHub MCP inactive"* ]]; then
        _fail "stderr unexpectedly contained hint: $stderr"
    fi
}
```

- [ ] **Step 1.2: Run the tests to confirm they fail**

Run: `bash tests/run.sh tests/test-gh-mcp-env.sh`

Expected: all 3 tests fail because `scripts/runtime/gh-mcp-env.sh` doesn't exist yet. Failure message will mention the source command failing.

- [ ] **Step 1.3: Implement `gh-mcp-env.sh`**

Create `scripts/runtime/gh-mcp-env.sh`:

```bash
#!/usr/bin/env bash
# gh-mcp-env.sh — Exports GITHUB_PERSONAL_ACCESS_TOKEN from gh CLI auth state so
# the github MCP server (https://api.githubcopilot.com/mcp/) activates for the
# Claude session. No-op (with a one-line stderr hint) if gh isn't installed or
# isn't authed.
#
# Sourced by start-claude*.sh just before exec'ing claude.
#
# Safe to source under `set -e`: the conditional consumes the exit status, so a
# missing or unauthed gh never aborts the caller.

if command -v gh &>/dev/null && gh auth status &>/dev/null; then
    export GITHUB_PERSONAL_ACCESS_TOKEN="$(gh auth token 2>/dev/null)"
else
    echo "ℹ GitHub MCP inactive — run 'gh auth login' to enable agent GitHub tools" >&2
fi
```

Make executable (not strictly required for a sourced script, but matches the repo convention for scripts in `scripts/runtime/`):

```bash
chmod +x scripts/runtime/gh-mcp-env.sh
```

- [ ] **Step 1.4: Run the tests to confirm they pass**

Run: `bash tests/run.sh tests/test-gh-mcp-env.sh`

Expected:
```
PASS test_gh_authed_exports_token_silently
PASS test_gh_installed_but_unauthed_no_export_with_hint
PASS test_gh_missing_no_export_with_hint

All 3 tests passed
```

- [ ] **Step 1.5: Commit**

```bash
git add scripts/runtime/gh-mcp-env.sh tests/test-gh-mcp-env.sh
git commit -m "Add gh-mcp-env.sh to export GITHUB_PERSONAL_ACCESS_TOKEN from gh auth"
```

---

## Task 2: Install `gh-mcp-env.sh` into the container at provision time

**Files:**
- Modify: `scripts/deploy/install.sh:339-343` — add a copy step next to the existing `statusline-command.sh` install block.

- [ ] **Step 2.1: Add the copy step in `install.sh`**

Locate the existing statusline install block at `scripts/deploy/install.sh:339-343`:

```bash
# Status line script — copy into ~/.claude/ so it's available inside the container
if [[ -f "$DEV_ENV/scripts/runtime/statusline-command.sh" ]]; then
    cp "$DEV_ENV/scripts/runtime/statusline-command.sh" ~/.claude/statusline-command.sh
    chmod +x ~/.claude/statusline-command.sh
    ok "Installed statusline-command.sh"
```

Immediately after the `ok "Installed statusline-command.sh"` line (still inside the same `if` block, before `# Build desired user-scope settings`), insert:

```bash
    # GitHub MCP auth bridge — sourced by start-claude*.sh to export
    # GITHUB_PERSONAL_ACCESS_TOKEN from gh CLI auth state.
    if [[ -f "$DEV_ENV/scripts/runtime/gh-mcp-env.sh" ]]; then
        cp "$DEV_ENV/scripts/runtime/gh-mcp-env.sh" ~/.claude/gh-mcp-env.sh
        chmod +x ~/.claude/gh-mcp-env.sh
        ok "Installed gh-mcp-env.sh"
    fi
```

- [ ] **Step 2.2: Smoke-check the edit**

Run (from repo root):
```bash
bash -n scripts/deploy/install.sh
```

Expected: no output (syntax OK).

Then run:
```bash
grep -n "gh-mcp-env.sh" scripts/deploy/install.sh
```

Expected: 3 matches — the comment line, the `cp` line, and the `ok` line.

- [ ] **Step 2.3: Commit**

```bash
git add scripts/deploy/install.sh
git commit -m "Install gh-mcp-env.sh into ~/.claude/ during provision"
```

---

## Task 3: Wire portable-mode launches to source the env script

**Files:**
- Modify: `scripts/portable/start-claude-portable.sh:158` — workspace session launch
- Modify: `scripts/portable/start-claude-portable.sh:170` — manager session launch

Both edits insert `source ~/.claude/gh-mcp-env.sh && ` immediately before `exec claude` inside the `bash -lc '...'` command string.

- [ ] **Step 3.1: Read the current launch lines to lock in exact context**

Run:
```bash
sed -n '155,175p' scripts/portable/start-claude-portable.sh
```

Expected output (confirm lines match before editing):
```
    session_name="claude-$(basename "$selected" | tr './:' '-')"
...
        "bash -lc 'cd \"$selected\" && exec claude'"
...
    exec tmux new-session -A -s "claude-manager" \
        "bash -lc 'cd \"$dir\" && exec claude --append-system-prompt-file \"$MANAGER_PROMPT\" \"Greet me and show what you can help with.\"'"
```

- [ ] **Step 3.2: Edit line 158 (workspace session launch)**

Replace:
```
        "bash -lc 'cd \"$selected\" && exec claude'"
```

with:
```
        "bash -lc 'cd \"$selected\" && source ~/.claude/gh-mcp-env.sh && exec claude'"
```

- [ ] **Step 3.3: Edit line 170 (manager session launch)**

Replace:
```
        "bash -lc 'cd \"$dir\" && exec claude --append-system-prompt-file \"$MANAGER_PROMPT\" \"Greet me and show what you can help with.\"'"
```

with:
```
        "bash -lc 'cd \"$dir\" && source ~/.claude/gh-mcp-env.sh && exec claude --append-system-prompt-file \"$MANAGER_PROMPT\" \"Greet me and show what you can help with.\"'"
```

- [ ] **Step 3.4: Syntax check**

Run:
```bash
bash -n scripts/portable/start-claude-portable.sh
```

Expected: no output.

- [ ] **Step 3.5: Confirm both source lines landed**

Run:
```bash
grep -c "source ~/.claude/gh-mcp-env.sh" scripts/portable/start-claude-portable.sh
```

Expected: `2`.

- [ ] **Step 3.6: Commit**

```bash
git add scripts/portable/start-claude-portable.sh
git commit -m "Source gh-mcp-env.sh before claude in portable-mode launches"
```

---

## Task 4: Wire host-mode workspace launch to source the env script

**Files:**
- Modify: `scripts/runtime/start-claude.sh:372` — workspace session only. Host-mode manager at line 388 is intentionally untouched (runs Claude on the host, where `gh` state and `~/.claude/gh-mcp-env.sh` don't exist — see spec section "Launch script integration").

- [ ] **Step 4.1: Read the current workspace launch line for exact context**

Run:
```bash
sed -n '370,374p' scripts/runtime/start-claude.sh
```

Expected output (confirm the docker exec line matches before editing):
```
    tmux new-session -A -s "$session_name" \
        "docker exec -it -e CLAUDE_MOBILE=\"${CLAUDE_MOBILE:-}\" -w '$container_path' ${CONTAINER_NAME} bash -lc 'exec claude'"
}
```

- [ ] **Step 4.2: Edit line 372 (workspace session docker exec)**

Replace:
```
        "docker exec -it -e CLAUDE_MOBILE=\"${CLAUDE_MOBILE:-}\" -w '$container_path' ${CONTAINER_NAME} bash -lc 'exec claude'"
```

with:
```
        "docker exec -it -e CLAUDE_MOBILE=\"${CLAUDE_MOBILE:-}\" -w '$container_path' ${CONTAINER_NAME} bash -lc 'source ~/.claude/gh-mcp-env.sh && exec claude'"
```

- [ ] **Step 4.3: Syntax check**

Run:
```bash
bash -n scripts/runtime/start-claude.sh
```

Expected: no output.

- [ ] **Step 4.4: Confirm source line landed once (host manager at 388 should NOT have it)**

Run:
```bash
grep -c "source ~/.claude/gh-mcp-env.sh" scripts/runtime/start-claude.sh
```

Expected: `1`.

Also confirm the manager launch was NOT touched:
```bash
grep -n "Greet me and show" scripts/runtime/start-claude.sh
```

Expected: one match; the line should still read `"bash -lc 'cd \"$dir\" && exec claude --append-system-prompt-file ...` (no `source` in it).

- [ ] **Step 4.5: Run the existing start-claude test suite to confirm no regression**

Run:
```bash
bash tests/run.sh tests/test-start-claude.sh
```

Expected: all tests pass (these test helper functions, which are unaffected by the launch-line edit).

- [ ] **Step 4.6: Commit**

```bash
git add scripts/runtime/start-claude.sh
git commit -m "Source gh-mcp-env.sh in host-mode workspace launch"
```

---

## Task 5: Add the "prefer GitHub MCP" nudge to the global CLAUDE.md template

**Files:**
- Modify: `scripts/runtime/claude-global.md` — add a short rule under the existing `## Tools available` section.

- [ ] **Step 5.1: Read the current `## Tools available` section**

Run:
```bash
sed -n '19,24p' scripts/runtime/claude-global.md
```

Expected:
```
## Tools available

- Standard dev tools: `git`, `gh`, `docker`, `node`, `python`, `ripgrep`, `fzf`, `jq`, `aws`.
- Mobile-friendly slash commands: `/s` (status), `/d` (deploy), `/l` (logs), `/fix`, `/ship`, `/review`.
- Workspace lifecycle: `/provision`, `/destroy`, `/update`, `/backup`, `/workspace`, `/tailscale`.
```

- [ ] **Step 5.2: Edit the file to add the nudge**

Replace:
```
## Tools available

- Standard dev tools: `git`, `gh`, `docker`, `node`, `python`, `ripgrep`, `fzf`, `jq`, `aws`.
- Mobile-friendly slash commands: `/s` (status), `/d` (deploy), `/l` (logs), `/fix`, `/ship`, `/review`.
- Workspace lifecycle: `/provision`, `/destroy`, `/update`, `/backup`, `/workspace`, `/tailscale`.
```

with:
```
## Tools available

- Standard dev tools: `git`, `gh`, `docker`, `node`, `python`, `ripgrep`, `fzf`, `jq`, `aws`.
- Mobile-friendly slash commands: `/s` (status), `/d` (deploy), `/l` (logs), `/fix`, `/ship`, `/review`.
- Workspace lifecycle: `/provision`, `/destroy`, `/update`, `/backup`, `/workspace`, `/tailscale`.

### GitHub operations

- Prefer the `github` MCP server's tool calls (e.g. `mcp__github__*`) over shell `gh api` / `gh pr` / `gh issue` / `gh repo` when both are available — typed inputs, less token overhead, structured errors.
- Keep using `gh` for `gh aw`, `gh auth`, and provisioning-script contexts where no MCP equivalent exists.
- MCP is active only when `GITHUB_PERSONAL_ACCESS_TOKEN` is set; session launch auto-exports from `gh auth token`. If MCP is inactive, fall back to `gh` silently.
```

- [ ] **Step 5.3: Confirm the edit landed**

Run:
```bash
grep -c "GitHub operations" scripts/runtime/claude-global.md
```

Expected: `1`.

- [ ] **Step 5.4: Commit**

```bash
git add scripts/runtime/claude-global.md
git commit -m "Add GitHub MCP preference rule to global CLAUDE.md template"
```

---

## Task 6: End-to-end verification

**Files:** none modified — read-only verification.

- [ ] **Step 6.1: Run the full test suite**

Run:
```bash
bash tests/run.sh
```

Expected: all tests pass, including the new `test-gh-mcp-env.sh` (3 tests) and all existing tests (no regressions).

- [ ] **Step 6.2: Static review — diff summary**

Run:
```bash
git log --oneline HEAD~5..HEAD
git diff --stat HEAD~5..HEAD
```

Expected output (5 commits, ~6 files touched including the new test and script):
```
Add GitHub MCP preference rule to global CLAUDE.md template
Source gh-mcp-env.sh in host-mode workspace launch
Source gh-mcp-env.sh before claude in portable-mode launches
Install gh-mcp-env.sh into ~/.claude/ during provision
Add gh-mcp-env.sh to export GITHUB_PERSONAL_ACCESS_TOKEN from gh auth

 docs/superpowers/plans/2026-04-20-github-mcp-default.md    | +NNN
 docs/superpowers/specs/2026-04-20-github-mcp-default-design.md | +NNN
 scripts/deploy/install.sh                                  |   6 +++
 scripts/portable/start-claude-portable.sh                  |   4 +-
 scripts/runtime/claude-global.md                           |   6 +++
 scripts/runtime/gh-mcp-env.sh                              |  15 +++++
 scripts/runtime/start-claude.sh                            |   2 +-
 tests/test-gh-mcp-env.sh                                   |  60 +++++++++
```

Plan/spec diff counts will vary; the other file counts should match within +/- a couple of lines.

- [ ] **Step 6.3: Manual smoke test (in a real provisioned workspace)**

Can be deferred to after merge. Sequence:
1. Run `scripts/deploy/install.sh` (or provision a fresh workspace via `/provision`) so `~/.claude/gh-mcp-env.sh` exists inside the container.
2. Via the login menu, pick a repo to launch.
3. In the launched Claude session, ask it: `echo "$GITHUB_PERSONAL_ACCESS_TOKEN" | head -c 10` — expect `gho_` or `ghu_` prefix (gh OAuth token shape).
4. Ask Claude: "list my open PRs on this repo." Confirm the tool call is `mcp__github__*` rather than `bash` running `gh pr list`.
5. Negative test: in the container, run `gh auth logout`, then relaunch a session. Confirm the stderr hint `ℹ GitHub MCP inactive — run 'gh auth login' to enable agent GitHub tools` prints once during launch, and the session still starts cleanly.

Outcome: if all the above hold, the change is production-ready. If step 4 shows Claude still shelling out to `gh`, check that the global CLAUDE.md nudge is actually being loaded (it's injected from `~/.claude/CLAUDE.md`, which `install.sh` creates from `scripts/runtime/claude-global.md` only if the file doesn't already exist — existing workspaces with a hand-edited CLAUDE.md won't auto-pick-up the nudge).

- [ ] **Step 6.4: No commit required** — verification only.

---

## Self-Review Notes

Ran through the completed plan against the spec:

**Spec coverage:**
- "gh-mcp-env.sh" section → Task 1 ✓
- "Install path" section → Task 2 ✓
- "Launch script integration" table (3 of 4 launches) → Tasks 3 and 4 ✓
- "Guidance in global CLAUDE.md" section → Task 5 ✓
- "Testing" section (smoke, graceful degradation, in-container consistency) → Task 6, steps 6.1/6.3 ✓
- "Rollback" and "Follow-ups" sections → no tasks needed (documented only)

**Placeholder scan:** None — every step has concrete code, exact commands, and expected output.

**Type consistency:** File paths are consistent throughout (`scripts/runtime/gh-mcp-env.sh`, `~/.claude/gh-mcp-env.sh`, `tests/test-gh-mcp-env.sh`). Test function names are internally consistent. The env var name `GITHUB_PERSONAL_ACCESS_TOKEN` matches the plugin's `.mcp.json` expectation.
