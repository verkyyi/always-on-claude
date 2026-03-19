# Workspace Updater

## Environment check

First, check if this is a provisioned host:
  test -f ~/dev-env/.provisioned && echo "provisioned" || echo "not provisioned"

If "not provisioned", tell the user:
"This command is only available on a provisioned workspace. SSH into your instance and use [m] to manage workspaces."
Then stop — do not proceed with any further steps.

---

You are applying updates to an always-on Claude Code workspace. The repo at `~/dev-env` has already been pulled to the latest version (by the systemd timer or manually). Your job is to inspect what changed and apply the necessary updates.

## Steps

1. Check if there's a pending update file:
   ```bash
   cat ~/.update-pending 2>/dev/null || echo "No pending updates"
   ```

2. If no pending file exists, pull manually and check:
   ```bash
   bash ~/dev-env/scripts/runtime/update.sh
   cat ~/.update-pending 2>/dev/null || echo "Already up to date"
   ```

3. If there are updates, inspect what changed:
   ```bash
   # The pending file contains before/after commit hashes
   # Use them to see exactly what files changed
   cat ~/.update-pending
   ```
   Then review the diff:
   ```bash
   git -C ~/dev-env diff <before>..<after> --stat
   git -C ~/dev-env diff <before>..<after>
   ```

4. Based on what changed, apply the appropriate updates. Common scenarios:

   - **Scripts changed** (`scripts/runtime/`, `scripts/deploy/`): Already live via bind mount — no action needed, just confirm.

   - **Dockerfile or docker-compose.yml changed**: Pull new image and restart container:
     ```bash
     cd ~/dev-env && sudo --preserve-env=HOME docker compose pull
     # Check for active sessions before restarting
     tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude-' || echo "No active sessions"
     ```
     If no active sessions, restart:
     ```bash
     cd ~/dev-env && sudo --preserve-env=HOME docker compose up -d
     sudo --preserve-env=HOME docker compose exec -T -u root dev bash -c "chown -R dev:dev /home/dev/projects /home/dev/.claude" 2>/dev/null || true
     sudo docker image prune -f
     ```
     If active sessions exist, warn the user and ask for confirmation before restarting.

   - **Statusline script changed** (`scripts/runtime/statusline-command.sh`): Re-copy to `~/.claude/`:
     ```bash
     cp ~/dev-env/scripts/runtime/statusline-command.sh ~/.claude/statusline-command.sh
     chmod +x ~/.claude/statusline-command.sh
     ```

   - **Slash commands changed** (`.claude/commands/`): Already live via bind mount — no action needed.

   - **install.sh changed**: Review what was added. If new system packages or config steps were added, run those specific steps manually. Do NOT re-run the entire install script.

   - **GitHub Actions changed** (`.github/`): No server-side action needed — these run in CI.

   - **CLAUDE.md or docs changed**: No action needed.

5. Clean up:
   ```bash
   rm -f ~/.update-pending
   ```

6. Summarize what was updated and any actions taken.

## Important

- Never restart the container without checking for active Claude sessions first
- If the user has active sessions and a restart is needed, explain what needs to happen and let them decide when
- For changes you're unsure about, describe what changed and ask the user what to do
- This runs on the **host**, not inside the container
