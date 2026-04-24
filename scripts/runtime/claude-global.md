# Global CLAUDE.md

Applies to every project in this workspace. Edit freely — this file is only installed once, then left alone by updates.

## Environment

- **Runtime**: isolated Docker container on AWS EC2, Ubuntu ARM64 (`aarch64`).
- **Shell**: bash/zsh inside tmux. Detach with tmux prefix + `d`. Reattach via SSH.
- **Working user**: `dev`. Home: `/home/dev`. Projects live under `~/projects/`.
- **Workspace manager repo**: `/home/dev/dev-env`.
- **Claude auth**: user-provided (BYO). Either `ANTHROPIC_API_KEY` env var or `claude login`. Never attempt to log in on the user's behalf.
- **AWS**: CLI v2 installed. Credentials, if configured, belong to the user. Pass `--region` explicitly — Route 53 domains always use `us-east-1`.

## Permissions

- **Auto-approve is broad** at the user settings level. Safe because the container is sandboxed and disposable — the same settings would be risky on a personal workstation. Don't suggest tightening permissions unless asked.
- Still confirm before **destructive** or **externally visible** actions: `rm -rf`, force-push, deleting branches/PRs, sending messages, posting to external services, anything that spends money.

## Tools available

- Standard dev tools: `git`, `gh`, `docker`, `node`, `python`, `ripgrep`, `fzf`, `jq`, `aws`.
- Mobile-friendly slash commands: `/s` (status), `/d` (deploy), `/l` (logs), `/fix`, `/ship`, `/review`.
- Workspace lifecycle: `/provision`, `/destroy`, `/update`, `/backup`, `/workspace`, `/tailscale`.

### GitHub operations

- Prefer the `github` MCP server's tool calls (e.g. `mcp__github__*`) over shell `gh api` / `gh pr` / `gh issue` / `gh repo` when both are available — typed inputs, less token overhead, structured errors.
- Keep using `gh` for `gh aw`, `gh auth`, and provisioning-script contexts where no MCP equivalent exists.
- MCP is active only when `GITHUB_PERSONAL_ACCESS_TOKEN` is set; session launch auto-exports from `gh auth token`. If MCP is inactive, fall back to `gh` silently.

## Communication defaults

- Terse. Lead with the answer. Skip recap and filler.
- Mobile context (`CLAUDE_MOBILE=1` or narrow terminal): extra-short, one line per status item, no wide tables.
- When showing long output (logs, diffs, file dumps), summarize first and ask before dumping.

## Git

- Commit style: imperative, sentence case, no period (`Add X`, `Fix Y in Z`). Under ~72 chars.
- Only create commits when asked. Never push without explicit request.

## Gotchas specific to this runtime

- `~/.claude.json` must exist as a **file**, not a directory, before container start.
- `~/.claude/debug/` and `~/.claude/remote-settings.json` must be pre-created.
- Container hostname is fixed (`claude-dev`) to keep OAuth state stable.
- Repo discovery uses `find $HOME -maxdepth 3` — deeper repos won't show in the picker.
