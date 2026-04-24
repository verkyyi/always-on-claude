# GitHub MCP as default for agent-driven GitHub ops

## Problem

Claude sessions spawned inside a `dev-env` workspace reach for `gh api` / `gh pr` / `gh issue` shell commands when doing GitHub work. This is token-expensive (verbose JSON, shell framing) and brittle (ad-hoc `--jq` filtering, stderr parsing for errors).

GitHub's official remote MCP server at `https://api.githubcopilot.com/mcp/` exposes the same operations as typed tool calls. The `github` plugin from the `claude-plugins-official` marketplace is already installed in this workspace, but dormant because its `.mcp.json` requires `GITHUB_PERSONAL_ACCESS_TOKEN` to be set in the environment and nothing in the workspace sets it.

## Goal

Make the github MCP active by default in every Claude session launched via the workspace login menu, reusing the user's existing `gh` CLI auth state so no new secret/token has to be provisioned. Nudge future agents to prefer MCP tools over shell `gh` calls for agent-driven operations.

## Non-goals

- Provisioning a separate GitHub PAT in SSM or any other secret store
- Running a local GitHub MCP server (Docker image) — remote hosted server is sufficient
- Migrating the provisioning scripts (`install.sh`, `setup-auth.sh`, `onboarding-prompt.txt`) off `gh` — these run before Claude exists
- Replacing `gh aw` or `gh auth` invocations — no MCP equivalent
- Rewriting existing slash commands (`.claude/commands/review.md`, `ship.md`, `s.md`) that shell out to `gh` — tracked as a follow-up after MCP is validated in real use

## Design

### Single source of truth: `scripts/runtime/gh-mcp-env.sh`

A small sourceable script installed into the container and sourced by every Claude launch path.

```bash
#!/usr/bin/env bash
# Export GITHUB_PERSONAL_ACCESS_TOKEN from gh CLI auth state so the github MCP
# server (https://api.githubcopilot.com/mcp/) activates for the Claude session.
# No-op (with stderr hint) if gh isn't installed or isn't authed.
if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
  export GITHUB_PERSONAL_ACCESS_TOKEN="$(gh auth token 2>/dev/null)"
else
  echo "ℹ GitHub MCP inactive — run 'gh auth login' to enable agent GitHub tools" >&2
fi
```

Guard rationale (matches existing house style in `install.sh`):

- `command -v gh` — handles "gh not installed"
- `gh auth status` — handles "gh installed but not authed" (exits non-zero)
- Short-circuit `&&` means the export line only runs when both checks pass; nothing is ever set to an empty string
- No `set -e` interaction — the `if` condition itself consumes the exit status

### Install path

`scripts/deploy/install.sh` copies `scripts/runtime/gh-mcp-env.sh` to `/home/dev/.claude/gh-mcp-env.sh` during provisioning, alongside the other claude config files (`statusline-command.sh`, etc.).

Ownership: `dev:dev`, mode `0755`.

### Launch script integration

Two launch scripts, two launches each. Three of the four launches run Claude *inside* the container and get the source line; the fourth (host-mode manager) runs Claude on the host and is intentionally left alone.

| Script | Launch | Runs Claude where? | Gets source? |
|---|---|---|---|
| `scripts/runtime/start-claude.sh` (host-mode) | workspace (line 372) | in container via `docker exec` | **yes** |
| `scripts/runtime/start-claude.sh` (host-mode) | manager (line 388) | on the host | **no** |
| `scripts/portable/start-claude-portable.sh` | workspace (line 158) | in container (already) | **yes** |
| `scripts/portable/start-claude-portable.sh` | manager (line 170) | in container (already) | **yes** |

Why the host-mode manager is skipped: it runs `bash -lc 'cd ... && exec claude'` directly on the EC2 host. The host doesn't install `gh`, doesn't maintain `gh auth` state, and `~/.claude/gh-mcp-env.sh` on the host is a separate filesystem from the container's. The host-mode manager is used for workspace lifecycle management (provisioning, updates) — not for agent-driven GitHub work that benefits from MCP. Keeping it untouched avoids a cross-environment complication with no real upside.

**Three concrete hunks (illustrative — exact escaping in implementation):**

`scripts/runtime/start-claude.sh` line 372:
```bash
"docker exec -it -e CLAUDE_MOBILE=\"${CLAUDE_MOBILE:-}\" -w '$container_path' ${CONTAINER_NAME} bash -lc 'source ~/.claude/gh-mcp-env.sh && exec claude'"
```

`scripts/portable/start-claude-portable.sh` line 158:
```bash
"bash -lc 'cd \"$selected\" && source ~/.claude/gh-mcp-env.sh && exec claude'"
```

`scripts/portable/start-claude-portable.sh` line 170:
```bash
exec tmux new-session -A -s "claude-manager" \
  "bash -lc 'cd \"$dir\" && source ~/.claude/gh-mcp-env.sh && exec claude --append-system-prompt-file \"$MANAGER_PROMPT\" \"Greet me and show what you can help with.\"'"
```

### Guidance in global CLAUDE.md

`scripts/runtime/claude-global.md` (the template that `install.sh` copies to `~/.claude/CLAUDE.md` at provision) gets a short rule under a new or existing section on tool preferences:

> **GitHub operations**: prefer the `github` MCP server's tool calls over shell `gh api` / `gh pr` / `gh issue` / `gh repo` when both are available — typed inputs, less token overhead, structured errors. Keep using `gh` for `gh aw`, `gh auth`, and provisioning-script contexts where no MCP equivalent exists.

Kept deliberately short (3 lines, no code examples, no tables) so it doesn't bloat the context-injected CLAUDE.md.

## Behavior matrix

| State | `GITHUB_PERSONAL_ACCESS_TOKEN` | GitHub MCP | Agent GitHub ops |
|---|---|---|---|
| `gh` installed + authed | set to `gh auth token` output | active | MCP tools preferred per CLAUDE.md |
| `gh` not installed | unset | inactive | falls back to `gh` shell (which is also missing — user would see standard shell errors) |
| `gh` installed but not authed | unset; stderr hint emitted | inactive | falls back to `gh` shell (also unauthed — standard `gh` errors) |
| Token rejected by `api.githubcopilot.com/mcp/` (e.g. OAuth-shaped token not accepted) | set, but MCP fails on first call | effectively inactive | agent falls back to `gh` shell on error |

The last row is the one unverified assumption — GitHub's remote MCP endpoint may or may not accept `gh`-OAuth-shaped tokens. If it rejects them, behavior degrades gracefully (agent falls back to `gh`), but MCP won't activate. The fallback path is "Option A" from the original brainstorm: user creates an explicit PAT and stores it in SSM. Tracked as a follow-up if needed.

## Failure modes and error handling

- **Launch script aborted by source failure**: not possible — `gh-mcp-env.sh` has no `set -e`, and its only failure path is the conditional's else branch (which just echoes).
- **`gh auth token` slow**: measured ~10-20ms on this container; negligible for a once-per-session cost.
- **Token leaks into child processes**: yes, by design — that's how the MCP server reads it. Container is single-user and sandboxed; not a concern in this environment. Users running `ps aux` or `env` in their own shell will see the token. CLAUDE.md already notes this container's low-security-boundary model.
- **Token rotation**: if the user re-runs `gh auth login`, the next launched Claude session automatically picks up the new token. No restart or explicit refresh needed.

## Testing

- **Smoke**: launch a session via the menu, ask Claude to list PRs on a repo. If MCP is active, the tool call appears as `mcp__github__*`; if inactive, Claude runs `gh pr list`.
- **Graceful degradation**: uninstall or un-auth `gh`, re-launch the menu, confirm stderr hint appears and Claude still starts cleanly.
- **In-container session consistency**: `env | grep GITHUB_PERSONAL_ACCESS_TOKEN` should return a value in both workspace and portable-mode manager sessions; the host-mode manager intentionally won't (documented, not a bug).

## Rollback

Single-file: revert the four launch-script hunks and delete `gh-mcp-env.sh`. The `claude-global.md` guidance line is additive and can stay or be dropped independently.

## Follow-ups (out of scope for this spec)

- Audit and migrate existing `gh`-using slash commands (`.claude/commands/review.md`, `ship.md`, `s.md`) to prefer MCP tool calls — once MCP is confirmed to work in real usage.
- If `api.githubcopilot.com/mcp/` rejects `gh`-shaped OAuth tokens, design a PAT-in-SSM path (the brainstorm's Option A) as a fallback.
- Add an integration test that exercises at least one MCP tool call at session start so we notice quickly if the remote endpoint changes.
