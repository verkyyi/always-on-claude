# Docker Architecture

## Container setup

- **Image**: `ghcr.io/verkyyi/always-on-claude:latest` (multi-arch: amd64 + arm64)
- **Base**: Ubuntu 24.04 + Node.js 22 + Claude Code (native installer)
- **Local build**: `docker compose -f docker-compose.yml -f docker-compose.build.yml build`

## Networking

Host networking (`network_mode: host`) — provides full network access including EC2 metadata.

## Volumes (bind mounts)

All data persists across container restarts via bind mounts:

| Host path | Container path | Purpose |
|---|---|---|
| `~/.claude` | `/home/dev/.claude` | Auth tokens, settings, history |
| `~/.claude.json` | `/home/dev/.claude.json` | Onboarding state |
| `~/projects` | `/home/dev/projects` | Code repos |
| `~/.gitconfig.d` | `/home/dev/.gitconfig.d` | Git config |
| `~/.ssh` | `/home/dev/.ssh` | SSH keys (read-only) |
| `~/dev-env` | `/home/dev/dev-env` | Scripts (read-only) |

## Key gotchas

1. **`~/.claude.json` must exist as a file** before first `docker compose up` — if Docker creates it as a directory, onboarding breaks. Use `echo '{}' > ~/.claude.json`.
2. **`~/.claude/debug/` and `~/.claude/remote-settings.json` must be pre-created** with correct ownership.
3. **Claude Code requires ripgrep, fzf, and zsh** — all included in the image.
4. **Container runs as `dev:dev` (UID/GID 1000:1000)** — Claude Code refuses to run as root.
5. **Fixed hostname** (`hostname: claude-dev`) prevents random hostnames breaking auth.
6. **Use `docker compose stop/start`** for daily work. Only `down/up` when the image updates.
