# CLAUDE.md

Affordable, isolated Claude Code runtime workspaces. Bring your own auth, SSH in, code.

## Target user

Solo developers on Mac. All tooling, docs, and setup flows assume a single user running macOS with AWS CLI and SSH available locally.

## Vision

Always-on Claude Code workspaces where we handle the runtime — container, persistence, dev tools, cross-device access — and users handle their own Claude auth. No server to manage, no ops burden.

## Lifecycle philosophy

The full workspace lifecycle — **provision, setup, update, destroy** — should be **Claude Code-guided first, scripts as fallback**. Users run slash commands (`/provision`, `/destroy`) and Claude orchestrates the AWS calls, handles errors intelligently, and walks them through interactive steps. Shell scripts (`scripts/deploy/provision.sh`, `scripts/deploy/destroy.sh`, `scripts/deploy/install.sh`) exist as fallbacks for automation, CI/CD, and environments without Claude Code.

## Business model: BYO Auth

Users bring their own Claude authentication. We provide the runtime only. We never provide, share, or manage Claude subscriptions or API keys on behalf of users.

**Two auth options (user's choice):**
- **API key** — user sets `ANTHROPIC_API_KEY`, pay-per-token, no caps, pick any model tier
- **Subscription** — user runs `claude login` with their own Pro/Max account

Both are the user's own account and credentials. We don't touch billing. We charge only for infrastructure.

## Why this over alternatives

| Alternative | Problem |
|---|---|
| Claude Code on the Web | Tied to $20-100/mo subscription, shared token quota, ephemeral sessions, no real server access |
| Claude mobile | Chat only — no code execution, no filesystem, no git |
| Claude CLI (local) | Tied to one machine, dies when terminal closes, no persistence |
| Self-hosted (DIY) | 15+ setup steps, manage your own server, handle updates yourself |

What we provide:
- **Always on** — sessions survive disconnects, work continues in background
- **Any device** — SSH from laptop, phone, tablet; same environment everywhere
- **Persistent** — tmux sessions, repos, auth, Claude context all survive across reconnects
- **Isolated** — each developer gets their own containerized workspace
- **Full dev environment** — git, Node.js, GitHub CLI, AWS CLI, build tools — not a sandboxed browser tab
- **Affordable** — cheap VPS + API tokens, no subscription markup
- **No token caps** — API billing means no "you've hit your limit" mid-session

## Project structure

All scripts are bash. No test suite — test manually via `docker compose up -d` (pulls pre-built image) or `docker compose -f docker-compose.yml -f docker-compose.build.yml build` for local builds.

```
Root (Docker config — stays here by convention):
  Dockerfile               — Ubuntu 24.04 + Node 22 + Claude Code + dev tools (multi-arch: amd64 + arm64)
  docker-compose.yml       — Single service, pre-built image from GHCR, host networking, bind mounts
  docker-compose.build.yml — Override for local builds (docker compose -f ... -f ... build)
  docker-compose.mac.yml   — Override for local Mac: bridge networking (replaces host mode)

scripts/deploy/ (provisioning & server setup — run from Mac or during first boot):
  provision.sh             — AWS provisioning: direct EC2 launch, ~40s with pre-built AMI
  destroy.sh               — Tear down EC2 resources by Project tag
  install.sh               — One-line server setup for EC2/Linux (pulls pre-built image)
  install-mac.sh           — One-line bootstrap for local Mac (Homebrew, Docker, launchd)
  install-updater.sh       — systemd timer for auto-updates (Linux/EC2)
  install-updater-mac.sh   — launchd agent for auto-updates (macOS)
  autostart-mac.sh         — launchd agent for container auto-start on login (macOS)
  build-ami.sh             — Build and publish pre-baked AMI (Docker + Claude Code pre-installed)
  setup-auth.sh            — Interactive auth: git config, gh auth login, claude login

scripts/runtime/ (day-to-day server use — run on SSH login or inside the container):
  ssh-login.sh             — Menu on SSH login: [1] Claude Code, [2] container bash, [3] host shell
  start-claude.sh          — Workspace picker, auto-starts container, launches Claude in tmux
  worktree-helper.sh       — Create/remove/list git worktrees for parallel sessions

scripts/demo/ (shared demo server — temporary accounts for try-before-you-buy):
  create-demo.sh           — Create a temporary demo user (host + container + SSH key)
  cleanup-demo.sh          — Remove expired demo users (cron job, every 15 min)
  install-demo.sh          — One-time setup: cron, process isolation, SSH hardening

CI/CD:
  .github/workflows/docker-publish.yml — Multi-arch build + push to GHCR on main
  .github/workflows/build-ami.yml      — Build and publish pre-baked AMI on image update

Add-ons (slash commands — live in .claude/commands/, auto-discovered):
  .claude/commands/provision.md        — Slash command: orchestrates full AWS provisioning via Claude
  .claude/commands/provision-local.md  — Slash command: orchestrates local Mac setup via Claude
  .claude/commands/destroy-local.md    — Slash command: tears down local Mac workspace
  .claude/commands/demo.md             — Slash command: create/manage demo accounts on demo server
```

## Bash conventions

Every script starts with `set -euo pipefail`. Common helper pattern:

```bash
info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
skip()  { echo "  SKIP: $* (already done)"; }
die()   { echo "ERROR: $*" >&2; exit 1; }
```

**Idempotency** — all setup scripts check before acting:
```bash
if command -v docker &>/dev/null; then
    skip "Docker"
else
    # install
    ok "Docker installed"
fi
```

**Guard clauses** for early exits:
```bash
[[ -n "${TMUX:-}" ]] && return
[[ "$-" != *i* ]] && return
```

**Arrays**: `mapfile -t arr < <(cmd)` then `for x in "${arr[@]}"`. Split with `IFS='|' read -r f1 f2 <<< "$entry"`.

**Sudo wrapping** when script may run as root or non-root:
```bash
if [[ $EUID -eq 0 ]]; then sudo() { "$@"; }; fi
```

## Workspace types

The project supports two deployment targets, tracked by `WORKSPACE_TYPE` in `.env.workspace`:

| Type | Where | Networking | Init system | Slash commands |
|------|-------|-----------|-------------|----------------|
| `ec2` | AWS EC2 instance | `network_mode: host` | systemd | `/provision`, `/destroy` |
| `local-mac` | Local Mac (mini/Studio) | `network_mode: bridge` | launchd | `/provision-local`, `/destroy-local` |

Shared commands (`/update`, `/tailscale`, `/workspace`) branch on `WORKSPACE_TYPE` where behavior differs. Missing type defaults to `ec2` for backward compatibility.

**Local Mac compose command:**
```bash
docker compose -f docker-compose.yml -f docker-compose.mac.yml up -d
```

**EC2 compose command:**
```bash
sudo --preserve-env=HOME docker compose up -d
```

## Docker architecture

- **Pre-built image** from `ghcr.io/verkyyi/always-on-claude:latest` (multi-arch: amd64 + arm64)
- **Local build override**: `docker compose -f docker-compose.yml -f docker-compose.build.yml build`
- **Host networking** (`network_mode: host`) — required for EC2 instance metadata / IAM roles
- **Bridge networking** (`docker-compose.mac.yml`) — required for Docker Desktop on macOS (host mode not supported)
- **Bind mounts** persist auth and projects across container rebuilds
- `~/.claude.json` is mounted **separately** from `~/.claude/` (onboarding state lives in home dir root, not inside .claude/)
- `~/.ssh` is mounted **read-only** — use HTTPS clones + `gh auth login`, not SSH git
- Container runs as `dev:dev` (UID/GID 1000:1000) — Claude Code refuses to run as root
- Use `docker compose stop/start` for daily work; only `down/up` when image updates

## Critical gotchas

1. **Claude Code silently fails without ripgrep, fzf, and zsh** — all three must be in the container
2. **`~/.claude.json` must exist as a file before first `docker compose up`** — if Docker creates it as a directory, onboarding state is lost every restart. Use `touch ~/.claude.json`.
3. **`~/.claude/debug/` and `~/.claude/remote-settings.json` must be pre-created** with correct ownership, or Claude crashes with ENOENT
4. **Auth is the user's responsibility** — either `ANTHROPIC_API_KEY` env var (API key) or `claude login` (their own subscription). We support both, never provide either. If using API key, it must be stored securely and injected into the container. If using subscription, OAuth state persists in the `~/.claude/` bind mount.
5. **Container hostname is fixed** (`hostname: claude-dev`) — prevents random hostnames across restarts
6. **Git repo discovery uses `find $HOME -maxdepth 3`** — repos nested deeper won't appear in workspace picker

## Commit style

Imperative, sentence case, no period: `Add feature`, `Fix bug in X`, `Update Y with Z`. Keep under ~72 chars.
