# Architecture

## Deployment modes

Three deployment targets, same container image:

| Mode | Where | Networking | Image tag | Slash commands |
|---|---|---|---|---|
| EC2 | AWS instance | `network_mode: host` | `:latest` | `/provision`, `/destroy` |
| Local Mac | Docker Desktop | `network_mode: bridge` | `:latest` | `/provision-local`, `/destroy-local` |
| Portable | Any machine with Docker | bridge (default) | `:portable` | n/a |

EC2 is the primary target. Portable mode is self-contained — no host setup scripts needed.

## Container

- **Base**: Ubuntu 24.04, runs as `dev:dev` (UID/GID 1000:1000) — Claude Code refuses root
- **Image**: `ghcr.io/verkyyi/always-on-claude:latest` (multi-arch: amd64 + arm64)
- **Portable image**: `ghcr.io/verkyyi/always-on-claude:portable` — extends base with Tailscale, cron/at, gosu, all scripts baked in
- **Hostname**: Fixed (`claude-dev`) — prevents random hostnames breaking OAuth state
- **Restart policy**: `unless-stopped`

### Installed tools

| Tool | Purpose |
|---|---|
| Claude Code | AI coding assistant (native installer) |
| Codex | OpenAI coding assistant CLI |
| Node.js 22 | Claude Code + Codex runtime + JS development |
| Bun | Fast JS runtime/package manager |
| Git, GitHub CLI | Version control, PR workflows |
| AWS CLI v2 | Cloud operations |
| ripgrep, fzf, zsh | Required by Claude Code (silently fails without them) |
| tmux, vim, jq | Session management, editing, JSON processing |
| Python 3, pip | Python development |
| uv | Python package manager, provides `uvx` for MCP servers |
| curl, build-essential | HTTP and compilation |

### Shell aliases

```
cc  → claude --dangerously-skip-permissions
cx  → codex --dangerously-bypass-approvals-and-sandbox
gs  → git status
gl  → git log --oneline -20
```

## Networking

**EC2 mode**: `network_mode: host` — full network access including EC2 instance metadata (IMDSv2). Required for IAM roles and instance identity.

**Mac/Portable mode**: Bridge networking — Docker Desktop on macOS does not support host networking.

## Volumes and persistence

### EC2 mode (bind mounts)

| Host path | Container path | Purpose |
|---|---|---|
| `~/.claude` | `/home/dev/.claude` | Auth tokens, settings, history, status line script |
| `~/.codex` | `/home/dev/.codex` | Codex auth tokens, config, session state |
| `~/.claude.json` | `/home/dev/.claude.json` | Onboarding state (separate from .claude/) |
| `~/projects` | `/home/dev/projects` | Code repos |
| `~/.gitconfig.d` | `/home/dev/.gitconfig.d` | Git config |
| `~/.config/gh` | `/home/dev/.config/gh` | GitHub CLI auth |
| `~/dev-env` | `/home/dev/dev-env` | Dev-env repo scripts/configs (read-only) |
| `~/.ssh` | `/home/dev/.ssh` | SSH keys (read-only) |
| `~/.ssh/known_hosts` | `/home/dev/.ssh/known_hosts` | Writable override for host fingerprints |

### Portable mode (named volumes)

| Volume | Mount | Purpose |
|---|---|---|
| `claude-data` | `/home/dev/.claude` | Auth, settings, onboarding state (via symlink) |
| `codex-data` | `/home/dev/.codex` | Codex auth, config, session state |
| `projects` | `/home/dev/projects` | Code repos |
| `gitconfig` | `/home/dev/.config/git` | Git config (XDG path) |
| `gh-config` | `/home/dev/.config/gh` | GitHub CLI auth |
| `overnight` | `/home/dev/overnight` | Scheduled task files |
| `tailscale-state` | `/var/lib/tailscale` | Tailscale identity |

### Critical gotcha: ~/.claude.json

`~/.claude.json` must exist as a **file** before first `docker compose up`. If missing, Docker creates it as a directory, breaking onboarding state.

- **EC2 mode**: `install.sh` pre-creates it with `echo '{}' > ~/.claude.json`
- **Portable mode**: `entrypoint.sh` stores the real file at `~/.claude/claude.json` and symlinks `~/.claude.json → ~/.claude/claude.json`, avoiding the Docker named-volume gotcha entirely

## Memory and resource limits

### Container limits

```yaml
mem_limit: 3g        # Hard memory cap
memswap_limit: 4g    # 3GB RAM + 1GB swap burst
```

### Host-level protections

| Component | What it does |
|---|---|
| **2GB swap** | Configured by `install.sh`, swappiness=10 (only under real pressure) |
| **earlyoom** | Kills processes at 5% free RAM / 10% free swap. Protects SSH/systemd, prefers killing node/claude |
| **OOM score protection** | SSH, Tailscale, SSM agent get score -900 (last to be killed) |
| **CloudWatch alarms** | Warning at >80% RAM for 10 min, critical at >90% for 1 min (optional, requires IAM permissions) |

### Session limits

Coding assistant sessions are memory-intensive (~650 MB each). The system auto-calculates the maximum:

```
OS reserve:    512 MB (Docker + SSH + earlyoom)
Per session:   ~650 MB
Max sessions:  min(memory_based, CPU_count)

Example (t4g.small, 2 GB RAM, 2 vCPU):
  memory_based = (2048 - 512) / 650 = 2
  cpu_based    = 2
  max          = min(2, 2) = 2
```

Override with `MAX_SESSIONS` env var. The session limit is enforced by `start-claude.sh` — new sessions are blocked when at capacity, but reattaching to existing sessions always works.

The tmux status bar shows `N/M sess` (active/max) via `tmux-status.sh`.

## Session management

### tmux architecture

Each workspace gets its own named tmux session:

| Session name | Purpose |
|---|---|
| `claude-<repo>-<branch>` | Claude Code in a specific repo/worktree |
| `codex-<repo>-<branch>` | Codex in a specific repo/worktree |
| `claude-manager` | Workspace management (clone, worktree, updates) |
| `claude-onboarding` / `codex-onboarding` | First-run guided setup |
| `shell-host` | Host bash shell |
| `shell-container` | Container bash shell |

Sessions run on the **host** (not inside the container), so they survive container restarts. The selected coding assistant runs inside the container via `docker exec`.
The workspace manager remains Claude-based because lifecycle commands still live in `.claude/commands/`.

### Schedule bridge

Provisioned hosts install a narrow scheduling bridge for container coding sessions:

- Container writes request JSON to `/home/dev/.aoc/schedule/inbox`.
- Host `always-on-claude-schedule-bridge.path` watches `~/.always-on-claude/schedule/inbox/*.json`.
- Host processor validates the request, submits a host `atd` job or managed user crontab entry, and stores status/logs under `~/.always-on-claude/schedule/`.
- The scheduled host job runs the command back inside the dev container with `docker compose exec -T -w <cwd> dev bash -lc <command>`.

Only the inbox is writable from the container. Status and logs are mounted read-only, and generated `at` job scripts live in host-only paths.

### Login flow

```
SSH connect
  → ssh-login.sh (sourced from .bash_profile)
    → Guard checks: interactive? not tmux? SSH session? NO_CLAUDE not set?
    → Mobile detection: terminal width < 60 → sets CLAUDE_MOBILE=1
    → Update notification: ~/.update-pending exists?
    → First run: ~/.workspace-initialized missing?
      → Yes: onboarding.sh (guided setup via the preferred assistant)
      → No: start-claude.sh (workspace picker)
```

### Workspace picker (start-claude.sh)

Two-layer menu:

**Layer 1 — Repository selection:**
```
  === Active sessions (1/2) ===
  [a1] codex-myproject-main (idle)

  === Repositories ===
  [1] projects/myproject (main)
  [2] projects/another-repo (develop)
  [m] Manage workspaces
  [h] Host shell
  [c] Container shell
```

**Layer 2 — Branch/worktree selection** (only shown if worktrees exist):
```
  === projects/myproject ===
  [1] main (repo)
  [2] feature-xyz (worktree)
  [b] ← Back
```

Repos are discovered via `find ~/projects -maxdepth 3 -name ".git"`. Repos nested deeper won't appear.

## Worktree system

Git worktrees enable parallel Claude Code or Codex sessions on different branches of the same repo. Managed by `worktree-helper.sh`:

| Command | What it does |
|---|---|
| `create <repo> <branch>` | Creates worktree at `<repo>--<sanitized-branch>` |
| `remove <worktree-path>` | Removes worktree and prunes |
| `list-repos` | Discovers all repos and worktrees under ~/projects |
| `list-worktrees <repo>` | Lists worktrees for a specific repo |
| `cleanup [--dry-run\|--force]` | Removes merged worktrees + stale ones (>7 days, unmerged) |

Branch names are sanitized (`/` → `-`). Cleanup fetches the latest default branch (main/master auto-detected) and checks merge status.

## Update pipeline

Two-stage design: **check** (automatic) → **apply** (user-initiated).

### Stage 1: Check (update.sh)

Runs every 6 hours via systemd timer (`install-updater.sh`). Fetch-only — never pulls or restarts.

```
git fetch (no pull)
  → Compare local HEAD vs remote HEAD
    → Same: remove ~/.update-pending, log "no updates"
    → Different: write ~/.update-pending with:
        - before/after commit hashes
        - needs_rebuild flag (Dockerfile/compose changes detected)
        - commit log of what changed
```

On next SSH login, `ssh-login.sh` shows "Updates available — run /update to apply."

### Stage 2: Apply (self-update.sh)

Triggered by `/update` slash command or running `self-update.sh` directly. Four steps:

1. **Repo**: `git pull --ff-only` — reports changed files
2. **Docker image**: Always pulls latest, compares digests. If image changed:
   - Checks for active Claude or Codex sessions
   - Interactive: prompts before restarting container
   - Non-interactive: sets restart-pending flag
3. **Host scripts**: Updates statusline-command.sh, tmux.conf, tmux-status.sh if changed
4. **Summary**: Reports what was updated, clears `~/.update-pending`

## Status line

Claude Code shows a custom status line in the terminal (configured in `settings.json`):

```
Opus  72% 720k  high
```

| Field | Source | Color |
|---|---|---|
| Model name | Shortened from model ID (opus/sonnet/haiku) | Cyan |
| Context remaining | Percentage + absolute tokens (k) | Green >30%, Yellow 10-30%, Red <10% |
| Effort level | From `settings.json` effortLevel | Cyan |

Implemented by `statusline-command.sh`, installed to `~/.claude/statusline-command.sh`.

## tmux configuration

Custom `tmux.conf` installed to `~/.tmux.conf`:

- **Prefix**: `C-a` (remapped from default `C-b`)
- **Status bar**: Session name (left) + active session count (right)
- **Theme**: Tokyo Night color scheme (#1a1b26 background, #7aa2f7 accents)
- **Mouse**: Enabled
- **History**: 50,000 lines
- **Mobile optimizations**: Custom word separators, aggressive resize (uses smallest *active* client)
- **Window list**: Hidden (single window is typical)

## Settings and permissions

`install.sh` generates `~/.claude/settings.json` with:

```json
{
  "permissions": { "defaultMode": "bypassPermissions" },
  "statusLine": {
    "type": "command",
    "command": "bash /home/dev/.claude/statusline-command.sh"
  },
  "mcpServers": {
    "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp"] },
    "fetch": { "command": "uvx", "args": ["mcp-server-fetch"] }
  }
}
```

Permission bypass is safe in the isolated container environment. MCP servers provide documentation lookup (context7) and HTTP fetching (fetch).
