# Workspace Updater

## Environment check

First, check if this is a provisioned host:
  test -f ~/dev-env/.provisioned && echo "provisioned" || echo "not provisioned"

If "not provisioned", tell the user:
"This command is only available on a provisioned workspace. SSH into your instance and use [m] to manage workspaces."
Then stop — do not proceed with any further steps.

---

You are applying updates to an always-on Claude Code workspace. This workspace supports **rolling updates with zero downtime** — updates are applied without interrupting active Claude Code sessions whenever possible.

**Important:** The docker compose command is:
```bash
sudo --preserve-env=HOME docker compose
```

Use this form throughout this command.

## Steps

1. Check for active Claude sessions first (critical for zero-downtime updates):
   ```bash
   echo "=== Active sessions ==="
   tmux list-sessions -F '#{session_name} #{?session_attached,(attached),(idle)}' 2>/dev/null | grep '^claude-' || echo "No active sessions"
   echo ""
   echo "=== Container status ==="
   docker ps --filter name=claude-dev --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
   ```

2. Check if there's a pending update file (may include a deferred restart from the rolling updater):
   ```bash
   cat ~/.update-pending 2>/dev/null || echo "No pending updates"
   ```

3. If the pending file contains `restart_pending=`, a previous update pulled a new image but deferred the restart because sessions were active. Check if sessions have ended and apply:
   ```bash
   # If restart_pending is set and no sessions are active, restart now
   tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude-' || echo "NO_ACTIVE_SESSIONS"
   ```
   If no active sessions, proceed to restart the container (see "Restart-required changes" below), then clean up the pending file.
   If sessions are still active, inform the user and present restart options (see below).

4. If no pending file exists, pull manually and check:
   ```bash
   bash ~/dev-env/scripts/runtime/update.sh
   cat ~/.update-pending 2>/dev/null || echo "Already up to date"
   ```

5. If there are updates, inspect what changed:
   ```bash
   cat ~/.update-pending
   ```
   Then review the diff:
   ```bash
   git -C ~/dev-env diff <before>..<after> --stat
   git -C ~/dev-env diff <before>..<after>
   ```

6. Based on what changed, apply the appropriate updates using the **zero-downtime** approach:

   ### No-restart changes (applied immediately, zero downtime)

   - **Scripts changed** (`scripts/runtime/`, `scripts/deploy/`): Already live via bind mount — no action needed, just confirm.

   - **Slash commands changed** (`.claude/commands/`): Already live via bind mount — no action needed.

   - **GitHub Actions changed** (`.github/`): No server-side action needed — these run in CI.

   - **CLAUDE.md or docs changed**: No action needed.

   - **Statusline script changed** (`scripts/runtime/statusline-command.sh`): Re-copy to `~/.claude/`:
     ```bash
     cp ~/dev-env/scripts/runtime/statusline-command.sh ~/.claude/statusline-command.sh
     chmod +x ~/.claude/statusline-command.sh
     ```

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

   ### Restart-required changes (zero-downtime approach)

   - **Dockerfile or docker-compose.yml changed**: These require a container restart. Follow the zero-downtime procedure:

     **Step A: Pull the new image first (no disruption)**
     ```bash
     cd ~/dev-env && sudo --preserve-env=HOME docker compose pull
     ```

     **Step B: Check for active sessions**
     ```bash
     echo "=== Active Claude sessions ==="
     tmux list-sessions -F '#{session_name} #{?session_attached,(attached),(idle)}' 2>/dev/null | grep '^claude-' || echo "No active sessions"
     echo ""
     echo "=== Claude processes in container ==="
     docker exec claude-dev pgrep -a claude 2>/dev/null || echo "No Claude processes running"
     ```

     **Step C: Apply the restart based on session state**

     If **no active sessions**: restart immediately:
     ```bash
     cd ~/dev-env && sudo --preserve-env=HOME docker compose up -d
     sudo --preserve-env=HOME docker compose exec -T -u root dev bash -c "chown -R dev:dev /home/dev/projects /home/dev/.claude" 2>/dev/null || true
     sudo docker image prune -f
     ```

     If **active sessions exist**: explain the situation to the user and present three options:
     1. **Wait** — the automated rolling updater will restart the container automatically when all sessions end (deferred restart). Write a marker:
        ```bash
        echo "restart_pending=$(date -Iseconds)" >> ~/.update-pending
        ```
     2. **Restart now** — apply immediately (will interrupt active sessions). Proceed with the restart commands above.
     3. **Schedule** — user restarts later manually:
        ```bash
        cd ~/dev-env && bash scripts/runtime/rolling-update.sh --force
        ```

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

7. Clean up:
   ```bash
   rm -f ~/.update-pending
   ```

8. Summarize what was updated and any actions taken.

## Important

- **Never restart the container without checking for active Claude sessions first**
- If the user has active sessions and a restart is needed, explain what needs to happen and let them decide when
- For changes you're unsure about, describe what changed and ask the user what to do
- This runs on the **host**, not inside the container
- The `rolling-update.sh` script handles automated zero-downtime updates via the systemd timer
- If the timer has already pulled changes and deferred a restart, you may just need to apply it
- Use `bash ~/dev-env/scripts/runtime/rolling-update.sh --check` to preview what an automated update would do
