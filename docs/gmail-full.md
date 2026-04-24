# gmail-full MCP

Optional helper for users who want a custom Gmail MCP alongside the official Gmail connector.

## What it does

`scripts/deploy/setup-gmail-full.sh`:

1. Copies `credentials.json` and `gcp-oauth.keys.json` into a private target dir
2. Configures `gmail-full` for Codex in `~/.codex/config.toml`
3. Configures `gmail-full` for Claude Code in the user-scoped MCP registry

The helper never writes OAuth files into the repo.

## Basic usage

If your source OAuth files already live in `~/.gmail-mcp`:

```bash
GMAIL_FULL_SOURCE_DIR="$HOME/.gmail-mcp" \
bash scripts/deploy/setup-gmail-full.sh
```

Or provide explicit file paths:

```bash
GMAIL_FULL_CREDENTIALS_FILE=/path/to/credentials.json \
GMAIL_FULL_OAUTH_FILE=/path/to/gcp-oauth.keys.json \
bash scripts/deploy/setup-gmail-full.sh
```

## Default target paths

- Provisioned hosts: `~/.codex/gmail-mcp`
- Non-provisioned/local machines: `~/.gmail-mcp`

The provisioned-host default is intentional. `~/.codex` is shared between the host and the container, so placing the OAuth files under `~/.codex/gmail-mcp` makes the same `gmail-full` setup work in both places.

Override the target if needed:

```bash
GMAIL_FULL_TARGET_DIR=/path/to/private-dir \
GMAIL_FULL_SOURCE_DIR="$HOME/.gmail-mcp" \
bash scripts/deploy/setup-gmail-full.sh
```

## Provisioned host notes

If you want to verify host-level Claude directly without entering the workspace picker, use the built-in bypass:

```bash
NO_CLAUDE=1 bash -lic 'claude mcp get gmail-full'
```

Read-only verification example:

```bash
NO_CLAUDE=1 bash -lic 'claude -p --permission-mode bypassPermissions --output-format text "Use the MCP server named gmail-full to do exactly one read-only email lookup. Search for the single most recent message in my inbox. Do not modify the mailbox. Return only three lines: STATUS: <ok or error>, FROM: <sender>, SUBJECT: <subject>."'
```

Container-side verification:

```bash
docker exec claude-dev bash -lc 'claude mcp get gmail-full'
docker exec claude-dev bash -lc 'codex mcp get gmail-full'
```
