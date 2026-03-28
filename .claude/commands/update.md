# Workspace Updater

## Environment check

First, check if this is a provisioned host:
  test -f ~/dev-env/.provisioned && echo "provisioned" || echo "not provisioned"

If "not provisioned", tell the user:
"This command is only available on a provisioned workspace. SSH into your instance and use [m] to manage workspaces."
Then stop — do not proceed with any further steps.

---

You are applying updates to an always-on Claude Code workspace.

**Important:** The docker compose command is:

```bash
sudo --preserve-env=HOME docker compose
```

Use this form throughout this command.

## Quick path: self-update script

For most updates, run the self-update script which handles everything automatically:

```bash
bash ~/dev-env/scripts/runtime/self-update.sh
```

The script follows a **fetch → preview → confirm → apply** flow:

1. Fetches latest changes (without applying)
2. Shows a categorized preview of ALL changes:
   - **Container changes** (Dockerfile/compose) — will require restart
   - **Runtime scripts** (start menu, ssh-login, etc.) — take effect immediately on pull
   - **Slash commands** — take effect immediately on pull
   - **Host-side configs** (statusline, tmux) — will be copied
   - **Deploy scripts** — provision-time only, no runtime effect
   - **Docs/CI** — no runtime effect
   - **Docker image** — checks registry for newer image
3. Asks user to confirm before applying anything
4. Applies: pulls repo, updates image, copies host scripts

If the script completes successfully, summarize the output for the user and stop here.

## Detailed path: manual inspection

If the self-update script fails, or if the user wants to inspect changes manually, fall back to this detailed workflow:

1. Check if there's a pending update file:

   ```bash
   cat ~/.update-pending 2>/dev/null || echo "No pending updates"
   ```

2. If no pending file exists, fetch and check:

   ```bash
   bash ~/dev-env/scripts/runtime/update.sh
   cat ~/.update-pending 2>/dev/null || echo "Already up to date"
   ```

3. If there are updates, inspect what changed:

   ```bash
   # The pending file contains before/after commit hashes and rebuild flag
   cat ~/.update-pending
   ```

   Then review the diff:

   ```bash
   git -C ~/dev-env diff <before>..<after> --stat
   git -C ~/dev-env diff <before>..<after>
   ```

4. **Pre-update backup** — Before applying any changes that require a container restart (Dockerfile, docker-compose changes), run a backup if one hasn't been taken already:

   ```bash
   # Check if update.sh already took a backup (it does this automatically for rebuilds)
   if [[ -d ~/backups/latest ]]; then
     echo "Backup exists:"
     cat ~/backups/latest/manifest.txt
   else
     echo "No backup found — running backup now"
     bash ~/dev-env/scripts/runtime/backup-state.sh
   fi
   ```

   If the backup reports repos with uncommitted changes, warn the user and ask for confirmation before proceeding.

5. Based on what changed, apply the appropriate updates. Common scenarios:

   - **Scripts changed** (`scripts/runtime/`, `scripts/deploy/`): Already live via bind mount — no action needed, just confirm.

   - **Dockerfile or docker-compose.yml changed**: Pull new image and restart container:

     ```bash
     cd ~/dev-env && sudo --preserve-env=HOME docker compose pull
     tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude-' || echo "No active sessions"
     ```

     If no active sessions, restart:

     ```bash
     cd ~/dev-env && sudo --preserve-env=HOME docker compose up -d
     sudo --preserve-env=HOME docker compose exec -T -u root dev bash -c "chown -R dev:dev /home/dev/projects /home/dev/.claude" 2>/dev/null || true
     sudo docker image prune -f
     ```

     If active sessions exist, warn the user and ask for confirmation before restarting.

     **After container restart, restore user state:**

     ```bash
     bash ~/dev-env/scripts/runtime/restore-state.sh
     ```

     This re-installs user-added packages, verifies bind mounts, and fixes permissions.

   - **Statusline script changed** (`scripts/runtime/statusline-command.sh`): Re-copy to `~/.claude/`:

     ```bash
     cp ~/dev-env/scripts/runtime/statusline-command.sh ~/.claude/statusline-command.sh
     chmod +x ~/.claude/statusline-command.sh
     ```

   - **Slash commands changed** (`.claude/commands/`): Already live via bind mount — no action needed.

   - **install.sh changed** (settings/config sections): If the diff shows changes to `~/.claude/settings.json` setup (e.g., new MCP servers), apply the same merge to the current workspace:

     ```bash
     # Example: merge new MCP server config into existing settings
     SETTINGS="$HOME/.claude/settings.json"
     DESIRED='{"mcpServers":{"context7":{"command":"npx","args":["-y","@upstash/context7-mcp"]},"fetch":{"command":"uvx","args":["mcp-server-fetch"]}}}'
     if [[ -f "$SETTINGS" ]]; then
       MERGED=$(jq -s '.[0] * .[1]' "$SETTINGS" <(echo "$DESIRED"))
       echo "$MERGED" > "$SETTINGS"
     else
       echo "$DESIRED" | jq . > "$SETTINGS"
     fi
     ```

     Adapt `DESIRED` to match whatever the install script now writes. User customizations are preserved via `jq` recursive merge.

   - **install.sh changed** (other sections): Review what was added. If new system packages or config steps were added, run those specific steps manually. Do NOT re-run the entire install script.

   - **GitHub Actions changed** (`.github/`): No server-side action needed — these run in CI.

   - **CLAUDE.md or docs changed**: No action needed.

6. Clean up:

   ```bash
   rm -f ~/.update-pending
   ```

7. Summarize what was updated and any actions taken. Include backup/restore status if applicable.

## Important

- Never restart the container without checking for active Claude sessions first
- If the user has active sessions and a restart is needed, explain what needs to happen and let them decide when
- Always back up state before container restarts — update.sh does this automatically for rebuilds, but verify a backup exists
- After a container restart, always run restore-state.sh to re-install user packages
- For changes you're unsure about, describe what changed and ask the user what to do
- This runs on the **host**, not inside the container
