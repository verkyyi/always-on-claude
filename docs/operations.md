# Operations

## First-run onboarding

On first SSH login, `ssh-login.sh` detects the absence of `~/.workspace-initialized` and launches `onboarding.sh` — a guided assistant session that walks through:

1. Git config (name, email)
2. GitHub auth (`gh auth login`)
3. Preferred assistant auth (`claude login`, `codex --login`, or API key)
4. Verify assistant auth/state inside the container
5. Cloning the first repo
6. Quick tour of the workspace

The onboarding session runs in tmux (`claude-onboarding` or `codex-onboarding`). When it ends (exit or detach), `~/.workspace-initialized` is created — subsequent logins skip straight to the workspace picker.

When `DEFAULT_CODE_AGENT=codex`, onboarding explicitly runs `codex --login` on the provisioned host first. On remote SSH hosts, the practical subscription path is the device-code browser step Codex shows, which still signs the workspace into the user's ChatGPT account. In portable mode, `start-claude-portable.sh` handles a simpler first-run check: if git config or GitHub CLI auth is missing, it offers to run `setup-auth.sh`.

## SSH login flow

`ssh-login.sh` is sourced from `.bash_profile` on every SSH login:

```
Guard checks:
  - Interactive shell? (skip for scp, rsync, etc.)
  - Not inside tmux? (avoid nesting)
  - SSH session? (skip for local terminals)
  - NO_CLAUDE != 1? (escape hatch)

If all pass:
  - Detect narrow terminal (<60 cols) → set CLAUDE_MOBILE=1
  - Show update notification if ~/.update-pending exists
  - First run → onboarding.sh
  - Otherwise → start-claude.sh (workspace picker)
```

**Bypass**: Set `NO_CLAUDE=1` to skip the workspace picker and get a plain shell:

```bash
ssh -o SendEnv=NO_CLAUDE claude-dev   # with NO_CLAUDE=1 in local env
```

## Workspace picker

Two-layer interactive menu presented on SSH login.

Set `DEFAULT_CODE_AGENT=codex` before install/provision, or export it on the host before launch, if you want repo selections to open Codex sessions by default. You can also press `t` in the workspace picker to toggle the default agent and persist it to `~/.bash_profile`. The manager path (`m`) still opens Claude because it relies on Claude slash commands.

Provisioned hosts also sync `~/.codex/config.toml` so Codex defaults to `approval_policy = "never"` and `sandbox_mode = "danger-full-access"`. That matches the intended trust model for these isolated workspaces and applies on both the host and inside the container via the shared `~/.codex` bind mount. The host additionally re-materializes repo-managed Codex home state directly from `scripts/runtime/codex-home/` and selected repo templates from `scripts/runtime/codex-projects/`, so global AGENTS, custom skills, and MCP wrappers do not depend on local plugin activation.

### Layer 1: Repository selection

```
  === Active sessions (1/2) ===
  [a1] codex-myproject-main (idle)

  === Repositories ===
  [1] projects/myproject (main)
  [2] projects/another-repo (develop)
  [t] Toggle default -> claude
  [m] Manage workspaces
  [h] Host shell
  [c] Container shell
```

| Key | Action |
|---|---|
| Number | Select a repo → Layer 2 (or launch directly if no worktrees) |
| `a1`, `a2`... | Reattach to existing tmux session |
| `t` | Toggle the default agent between Claude and Codex |
| `m` | Launch workspace manager (Claude with management prompt) |
| `h` | Host bash shell in tmux |
| `c` | Container bash shell in tmux |
| Enter | Default: first repo |

### Layer 2: Branch/worktree selection

Only shown if the selected repo has worktrees:

```
  === projects/myproject ===
  [1] main (repo)
  [2] feature-xyz (worktree)
  [b] ← Back
```

### Session limit enforcement

New sessions are blocked when at capacity:

```
  Session limit reached (2/2).
  Each coding session uses ~650 MB — more sessions risk OOM.

  Options:
    - Re-attach to an existing session (select it from the menu)
    - Exit a running session (Ctrl-b d to detach, then /exit inside it)
```

Reattaching to existing sessions always works regardless of the limit.

### Repo discovery

Repos are found via `find ~/projects -maxdepth 3 -name ".git"`. Repos nested deeper than 3 levels won't appear in the menu.

## Worktree management

Git worktrees enable parallel Claude Code or Codex sessions on different branches of the same repo.

### Via slash command

```
/workspace
```

Claude provides the workspace-management menu for cloning repos, creating/removing worktrees, and cleanup.

### Via script

```bash
# Create a worktree
bash scripts/runtime/worktree-helper.sh create /path/to/repo feature-branch

# Remove a worktree
bash scripts/runtime/worktree-helper.sh remove /path/to/repo--feature-branch

# List all repos and worktrees
bash scripts/runtime/worktree-helper.sh list-repos

# List worktrees for a repo
bash scripts/runtime/worktree-helper.sh list-worktrees /path/to/repo

# Clean up merged/stale worktrees
bash scripts/runtime/worktree-helper.sh cleanup --dry-run
bash scripts/runtime/worktree-helper.sh cleanup           # remove merged only
bash scripts/runtime/worktree-helper.sh cleanup --force    # also remove stale unmerged
```

### Worktree naming

Worktrees are created at `<repo-path>--<sanitized-branch>`. Branch names are sanitized: `/` → `-`.

Example: `~/projects/myproject` + branch `feature/auth` → `~/projects/myproject--feature-auth`

### Cleanup rules

| Condition | Action |
|---|---|
| Branch merged into default (main/master) | Removed automatically |
| Branch unmerged, last commit >7 days ago | Listed as stale, removed only with `--force` |
| Branch unmerged, last commit ≤7 days ago | Listed as active, kept |
| Detached HEAD | Listed as active, kept |

Cleanup fetches the latest default branch for accurate merge checks and auto-detects main vs. master.

## Updates

Two-stage design: automatic **check** → user-initiated **apply**.

### Checking for updates

The systemd timer (`claude-update.timer`) runs `update.sh` every 6 hours:

- Fetches latest from remote (no pull)
- Compares local HEAD vs remote HEAD
- If different, writes `~/.update-pending` with commit hashes and rebuild flag
- On next SSH login, shows: "Updates available — run /update to apply."

### Applying updates

```
/update
```

Or manually: `bash scripts/runtime/self-update.sh`

**Steps:**

1. `git pull --ff-only` — shows what changed
2. Pulls latest Docker image, compares digests
3. If image changed and active sessions exist → prompts before restarting
4. Updates host-side scripts (statusline, tmux config) if changed
5. Clears `~/.update-pending`

Container restarts are safe — tmux sessions run on the host and survive restarts.

## Slash commands

### Lifecycle commands

Run from a Claude session in the always-on-claude repo:

| Command | What it does |
|---|---|
| `/provision` | Launch a new workspace on AWS (~40s with pre-built AMI) |
| `/destroy` | Tear down all AWS resources by Project tag |
| `/update` | Apply pending updates (repo, image, scripts) |
| `/tailscale` | Set up Tailscale for private SSH access |
| `/workspace` | Manage repos and git worktrees |
| `/backup` | EBS snapshot management (create/list/restore/prune) |

### Mobile-friendly commands

Short aliases designed for phone typing:

| Command | What it does |
|---|---|
| `/s` | Status: git state, open PRs, instance health |
| `/d` | Deploy current project (auto-detects project type) |
| `/l` | Show recent logs (Docker, systemd, or file-based) |
| `/fix` | Find failing tests, fix them, commit |
| `/ship` | Merge PR, deploy, verify health |
| `/review` | Summarize open PRs, approve/merge |

### How slash commands work

Commands live in `.claude/commands/` and are auto-discovered by Claude Code when running in this repo. No manual installation needed — just clone the repo and run `claude`.

Codex support is runtime-level today: SSH-launched repo sessions, onboarding, auth persistence, and interactive coding work. The lifecycle slash-command control plane remains Claude-based.

### Mobile detection

When the terminal is narrow (width < 60 columns), `ssh-login.sh` sets `CLAUDE_MOBILE=1`. This signals Claude Code to:

- Keep responses concise
- Summarize before dumping long output
- Use compact formatting
- Avoid wide tables

## Daily operations

### Starting and stopping

```bash
# SSH in — workspace picker appears automatically
ssh claude-dev

# Detach from session (keep it running)
Ctrl-b d

# Stop the instance (saves money, preserves data)
aws ec2 stop-instances --instance-ids i-xxx

# Start it back up
aws ec2 start-instances --instance-ids i-xxx
ssh claude-dev    # picks up where you left off
```

### Container management

```bash
# Daily work — stop/start preserves container state
cd ~/dev-env && sudo docker compose stop
cd ~/dev-env && sudo docker compose start

# Image update — down/up recreates container (data persists via volumes)
cd ~/dev-env && sudo docker compose down
cd ~/dev-env && sudo docker compose up -d
```

### Tmux basics

| Key | Action |
|---|---|
| `Ctrl-a d` | Detach (session keeps running) |
| `Ctrl-a [` | Scroll mode (q to exit) |
| `Ctrl-a c` | New window |
| `Ctrl-a n/p` | Next/previous window |

Note: Prefix is `Ctrl-a` (not the default `Ctrl-b`).
