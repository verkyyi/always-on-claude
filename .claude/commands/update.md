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

This single command:

1. Pulls the latest repo changes
2. Updates Claude Code binary inside the container
3. Pulls a new Docker image (only if Dockerfile/compose changed or registry has a newer image)
4. Updates host-side scripts (statusline, tmux config)
5. Reports what was updated

If the script completes successfully with no issues, summarize the output for the user and stop here.

## Detailed path: manual inspection

If the self-update script fails, or if the user wants to inspect changes manually, fall back to this detailed workflow:

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

   - **System user rename** (install.sh contains user rename and current user is `ubuntu`): Apply the rename directly:

     ```bash
     sudo sed -i '/^ubuntu:/ { s/^ubuntu:/dev:/; s|:/home/ubuntu:|:/home/dev:| }' /etc/passwd
     sudo sed -i 's/^ubuntu:/dev:/' /etc/shadow /etc/group /etc/gshadow /etc/subuid /etc/subgid 2>/dev/null || true
     sudo mv /home/ubuntu /home/dev 2>/dev/null || true
     [[ -f /etc/sudoers.d/90-cloud-init-users ]] && sudo sed -i 's/ubuntu/dev/g' /etc/sudoers.d/90-cloud-init-users
     export USER=dev HOME=/home/dev
     ```

     Then tell the user:

     1. The host user has been renamed from `ubuntu` to `dev`
     2. They must disconnect (Ctrl-b d, then exit) and reconnect as `dev@`
     3. Update their local SSH config: change `User ubuntu` to `User dev` in `~/.ssh/config`
     4. Update shell aliases if they use `cc`/`ccc`

   - **GitHub Actions changed** (`.github/`): No server-side action needed — these run in CI.

   - **CLAUDE.md or docs changed**: No action needed.

5. Check for Claude Code binary updates:

   ```bash
   cat ~/.claude-version-check 2>/dev/null || echo "No version check data"
   ```

   If status is "update-available", inform the user:

   - Current version and available version
   - They can run `/update-claude-code` to update the binary
   - Or set `CLAUDE_AUTO_UPDATE=1` in their environment to auto-update

6. Clean up:

   ```bash
   rm -f ~/.update-pending
   ```

7. Summarize what was updated and any actions taken.

## Important

- Never restart the container without checking for active Claude sessions first
- If the user has active sessions and a restart is needed, explain what needs to happen and let them decide when
- For changes you're unsure about, describe what changed and ask the user what to do
- This runs on the **host**, not inside the container
