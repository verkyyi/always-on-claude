You are tearing down a local Mac always-on Claude Code workspace. Confirm with the user before deleting anything.

## Environment check

First, load the workspace info:
```bash
cat .env.workspace 2>/dev/null || echo "NOT FOUND"
```

If `.env.workspace` is missing, tell the user:
"No workspace found. Nothing to tear down."
Then stop.

Source the file to get `WORKSPACE_TYPE`, `HOSTNAME`, `DEV_ENV`.

If `WORKSPACE_TYPE` is not `local-mac`, tell the user:
"This workspace is type '$WORKSPACE_TYPE', not a local Mac. Use `/destroy` for EC2 workspaces."
Then stop.

---

## Step 1 — Confirm teardown

Show the user what will be removed:

```
This will tear down the local Mac workspace:

  Hostname:  $HOSTNAME
  Type:      local-mac

  What will be removed:
    1. Docker container (claude-dev)
    2. Launchd agents (auto-start + auto-updater)
    3. Shell integration (ssh-login.sh from .zprofile)
    4. SSH config (AcceptEnv NO_CLAUDE)
    5. Shell aliases (cc, ccc from .zshrc)
    6. Workspace env file (.env.workspace)

  What will NOT be removed:
    - ~/projects (your code)
    - ~/.claude (your auth + settings)
    - ~/dev-env (the repo)
    - Docker itself
    - Homebrew packages

  To also remove project data, tell me after teardown.

Proceed? [y/N]
```

Wait for explicit confirmation before proceeding.

---

## Step 2 — Stop and remove container

```bash
cd ~/dev-env && docker compose -f docker-compose.yml -f docker-compose.mac.yml down 2>/dev/null || true
```

Verify:
```bash
docker ps -a --format '{{.Names}}' | grep claude-dev || echo "removed"
```

---

## Step 3 — Unload launchd agents

```bash
launchctl bootout "gui/$(id -u)/com.always-on-claude.container" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.always-on-claude.update" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.always-on-claude.container.plist
rm -f ~/Library/LaunchAgents/com.always-on-claude.update.plist
```

---

## Step 4 — Remove shell integration

Remove the `ssh-login.sh` source line from `~/.zprofile`:
- Show the line(s) to be removed
- Confirm with user
- Remove only the ssh-login.sh line and its comment

Remove `cc` and `ccc` aliases from `~/.zshrc`:
- Show the lines to be removed
- Confirm with user
- Remove only the alias lines and their comment

Tell the user to run `source ~/.zshrc` afterward.

---

## Step 5 — Remove SSH config

Check if AcceptEnv NO_CLAUDE was added to `/etc/ssh/sshd_config`:
```bash
grep 'AcceptEnv NO_CLAUDE' /etc/ssh/sshd_config 2>/dev/null
```

If found, offer to remove it (requires sudo). Don't force — the user may want to keep SSH access.

---

## Step 6 — Clean up workspace file

```bash
rm -f .env.workspace
rm -f ~/dev-env/.provisioned
```

---

## Step 7 — Optional: Remove project data

Ask the user if they also want to remove:
- `~/projects` — all cloned repositories
- `~/.claude` — Claude auth, settings, history
- `~/dev-env` — this repo

**Only remove these if explicitly confirmed.** These contain user data.

---

## Step 8 — Summary

```
Local Mac workspace torn down.

  Removed:
    - Container: claude-dev
    - Launchd agents: auto-start + auto-updater
    - Shell integration: .zprofile, .zshrc aliases
    - Workspace config: .env.workspace

  Still present:
    - ~/projects (your code)
    - ~/.claude (your auth)
    - ~/dev-env (repo — safe to delete manually)
    - Docker, Homebrew packages

  To re-provision: /provision-local
```

---

## Important

- This runs on the **local Mac**, not inside the container
- ALWAYS confirm before removing anything
- Never remove `~/projects` or `~/.claude` without explicit confirmation
- If the container has active tmux sessions, warn the user before stopping
