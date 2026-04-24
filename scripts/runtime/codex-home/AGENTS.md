# Global AGENTS.md

Applies to every project in this workspace unless a closer `AGENTS.md` overrides it.

## Environment

- Runtime: isolated Docker container on AWS EC2, Ubuntu ARM64 (`aarch64`), Linux 6.17.
- User: `dev`. Home: `/home/dev`. Projects live under `~/projects/`.
- Shell: bash/zsh inside tmux. Detach with tmux prefix + `d`. Reattach over SSH/Tailscale.
- Most coding sessions run inside the `claude-dev` container. Host-side management scripts live in `/home/dev/dev-env`.
- Primary repo for the workspace manager itself: `/home/dev/dev-env`.
- AWS CLI is installed and authenticated in account `805425385773`. Pass `--region` explicitly when it matters; Route 53 operations should use `us-east-1`.
- Codex auth is already configured on this machine. Do not ask the user to re-authenticate unless a command actually fails with an auth/authz error.

## Permissions

- This host is intentionally configured for `approval_policy = "never"` and `sandbox_mode = "danger-full-access"`.
- Treat this as a trusted, externally sandboxed workspace. Do not waste turns asking for routine permission escalation.
- Still pause before destructive or externally visible actions: `rm -rf`, force-push, deleting branches/PRs, sending messages, posting to external services, or anything that spends money or changes cloud infrastructure.

## Tools

- Core tools: `git`, `gh`, `docker`, `node`, `npm`, `python3`, `uv`, `bun`, `rg`, `jq`, `tmux`, `aws`.
- Codex plugins currently enabled: GitHub, Gmail, Google Calendar, Canva.
- Prefer repo-local scripts, CLIs, and checked-in workflows over ad hoc long shell pipelines when they already exist.

## Communication

- Be terse. Lead with the answer.
- Prefer small actionable diffs over long explanations.
- When output is large, summarize first.
- Ask before dumping large logs, diffs, or file contents.

## Git

- Commit messages: imperative, sentence case, no period.
- Only create commits when asked.
- Never push without explicit request.

## Working Style

- Prefer repo `AGENTS.md`, repo-local skills, and repo scripts when present. More specific guidance wins over this file.
- For code changes, run relevant tests/lint/type checks when practical and report exactly what was verified.
- When the same mistake appears twice, propose a precise `AGENTS.md` or skill update instead of repeating the mistake.

## Runtime Gotchas

- `~/.codex` and `~/.claude` are bind-mounted into the container, so auth and session state should survive container restarts.
- `~/.claude.json` must remain a file, not a directory.
- Container hostname is fixed (`claude-dev`) to keep auth state stable.
- Keep active repos under `~/projects` if you want them to show up in the workspace picker.
