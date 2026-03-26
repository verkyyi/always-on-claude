# CLAUDE.md

Affordable, isolated Claude Code runtime workspaces. Bring your own auth, SSH in, code.

For detailed reference, see [docs/](docs/): [architecture](docs/architecture.md), [deployment](docs/deployment.md), [operations](docs/operations.md), [CI/CD](docs/ci-cd.md).

## Target user

Solo developers. All tooling, docs, and setup flows assume a single user with AWS CLI and SSH available locally.

## Vision

Always-on Claude Code workspaces where we handle the runtime — container, persistence, dev tools, cross-device access — and users handle their own Claude auth. No server to manage, no ops burden.

## Lifecycle philosophy

The full workspace lifecycle — **provision, setup, update, destroy** — should be **Claude Code-guided first, scripts as fallback**. Users run slash commands (`/provision`, `/destroy`) and Claude orchestrates the AWS calls, handles errors intelligently, and walks them through interactive steps. Shell scripts exist as fallbacks for automation, CI/CD, and environments without Claude Code.

## Business model: BYO Auth

Users bring their own Claude authentication. We provide the runtime only. We never provide, share, or manage Claude subscriptions or API keys on behalf of users.

**Two auth options (user's choice):**

- **API key** — user sets `ANTHROPIC_API_KEY`, pay-per-token, no caps, pick any model tier
- **Subscription** — user runs `claude login` with their own Pro/Max account

Both are the user's own account and credentials. We don't touch billing. We charge only for infrastructure.

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

## Configuration

All deployment parameters live in a single `.env` file at the repo root. Scripts load it via `scripts/deploy/load-config.sh`.

**Resolution order** (later wins):

1. Defaults (hardcoded in `load-config.sh`)
2. `.env` file
3. Environment variables at runtime

This means `INSTANCE_TYPE=t3.medium bash provision.sh` overrides whatever is in `.env`. See [deployment.md](docs/deployment.md) for the full variable reference.

## Critical gotchas

1. **Claude Code silently fails without ripgrep, fzf, and zsh** — all three must be in the container
2. **`~/.claude.json` must exist as a file before first `docker compose up`** — if Docker creates it as a directory, onboarding state is lost every restart. Use `touch ~/.claude.json`.
3. **`~/.claude/debug/` and `~/.claude/remote-settings.json` must be pre-created** with correct ownership, or Claude crashes with ENOENT
4. **Auth is the user's responsibility** — either `ANTHROPIC_API_KEY` env var (API key) or `claude login` (their own subscription). We support both, never provide either.
5. **Container hostname is fixed** (`hostname: claude-dev`) — prevents random hostnames breaking OAuth state
6. **Git repo discovery uses `find $HOME -maxdepth 3`** — repos nested deeper won't appear in workspace picker

## Mobile-friendly output

When the terminal is narrow (CLAUDE_MOBILE=1 is set, or terminal width < 60 columns), optimize output for small screens:

- Keep responses concise. Lead with the answer, not the reasoning.
- For long output (logs, diffs, file contents), summarize first, ask before dumping full content.
- Use compact single-line-per-item format for status.
- Prefer short confirmations over multi-paragraph explanations.
- Avoid tables wider than 50 columns.
- Use short slash commands (`/s`, `/d`, `/l`, `/fix`, `/ship`, `/review`) — designed for mobile typing.

**Permission auto-approve**: In our isolated container, broad auto-approve is pre-configured at the user settings level. This eliminates most approve/deny prompts, which is critical on mobile where every tap costs effort. This is safe in our sandboxed environment but would be risky on a personal workstation.

## Commit style

Imperative, sentence case, no period: `Add feature`, `Fix bug in X`, `Update Y with Z`. Keep under ~72 chars.
