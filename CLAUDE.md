# CLAUDE.md

Affordable, isolated Claude Code runtime workspaces. Bring your own auth, SSH in, code.

## Target user

Solo developers on Mac. All tooling, docs, and setup flows assume a single user running macOS with AWS CLI and SSH available locally.

## Vision

Always-on Claude Code workspaces where we handle the runtime — container, persistence, dev tools, cross-device access — and users handle their own Claude auth. No server to manage, no ops burden.

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
Core (the always-on experience):
  Dockerfile          — Ubuntu 24.04 + Node 22 + Claude Code + dev tools (multi-arch: amd64 + arm64)
  docker-compose.yml  — Single service, pre-built image from GHCR, host networking, bind mounts
  docker-compose.build.yml — Override for local builds (docker compose -f ... -f ... build)
  ssh-login.sh        — Menu on SSH login: [1] Claude Code, [2] container bash, [3] host shell
  start-claude.sh     — Workspace picker, auto-starts container, launches Claude in tmux
  worktree-helper.sh  — Create/remove/list git worktrees for parallel sessions

Deployment:
  install.sh          — One-line server setup (pulls pre-built image, optional Tailscale/overnight)
  provision.sh        — AWS provisioning: direct EC2 launch, ~40s with pre-built AMI
  destroy.sh          — Tear down EC2 resources by Project tag
  build-ami.sh        — Build and publish pre-baked AMI (Docker + Claude Code pre-installed)
  setup-auth.sh       — Interactive auth: git config, gh auth login, claude login
  .github/workflows/docker-publish.yml — Multi-arch build + push to GHCR on main

Add-ons (slash commands):
  commands/provision.md       — Slash command: orchestrates full AWS provisioning via Claude
  commands/plan-overnight.md  — Slash command: scans TODOs/issues, writes task file
  trigger-watcher.sh          — Host cron: detects .scheduled files, runs `at`
  run-tasks.sh                — Parses task file, runs each via `claude -p`, logs output
  overnight-tasks.sh          — Simpler manual alternative

Add-ons (git health):
  git-check.sh        — Daily repo health: uncommitted changes, lint, tests, coverage
  git-check.cron      — Cron definition for daily git-check at 08:00

Secrets:
  load-secrets.sh     — Sources AWS SSM parameters into env vars
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

## Docker architecture

- **Pre-built image** from `ghcr.io/verkyyi/always-on-claude:latest` (multi-arch: amd64 + arm64)
- **Local build override**: `docker compose -f docker-compose.yml -f docker-compose.build.yml build`
- **Host networking** (`network_mode: host`) — required for EC2 instance metadata / IAM roles
- **Bind mounts** persist auth, projects, and task data across container rebuilds
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
