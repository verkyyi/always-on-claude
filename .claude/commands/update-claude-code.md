# Update Claude Code Binary

## Environment check

First, check if this is a provisioned host:
  test -f ~/dev-env/.provisioned && echo "provisioned" || echo "not provisioned"

If "not provisioned", tell the user:
"This command is only available on a provisioned workspace. SSH into your instance and use [m] to manage workspaces."
Then stop — do not proceed with any further steps.

---

You are updating the Claude Code binary inside the container.

## Steps

1. Check current version status:
   ```bash
   cat ~/.claude-version-check 2>/dev/null || echo "No version check data — running check now"
   ```

2. If no version check data exists, run the check:
   ```bash
   bash ~/dev-env/scripts/runtime/check-claude-version.sh
   cat ~/.claude-version-check 2>/dev/null || echo "Could not determine version status"
   ```

3. If status is "current", tell the user they're already on the latest version and stop.

4. If status is "update-available", show the user:
   - Current version (installed=)
   - Available version (latest=)
   - Ask for confirmation to update

5. If the user confirms, update Claude Code inside the container:
   ```bash
   docker exec -u dev claude-dev bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
   ```

6. Verify the update:
   ```bash
   docker exec claude-dev claude --version
   ```

7. Log the update:
   ```bash
   echo "[$(date '+%Y-%m-%d %H:%M:%S')] Manual update: $(cat ~/.claude-version-check | grep installed | cut -d= -f2) -> $(docker exec claude-dev claude --version)" >> ~/.claude/claude-updates.log
   ```

8. Update the state file:
   ```bash
   NEW_VERSION=$(docker exec claude-dev claude --version)
   cat > ~/.claude-version-check <<EOF
   status=current
   installed=$NEW_VERSION
   latest=$NEW_VERSION
   checked=$(date -Iseconds)
   manual_updated=$(date -Iseconds)
   EOF
   ```

9. Tell the user:
   - The update was successful
   - Active Claude sessions will use the new version when they restart
   - They can detach (Ctrl-b d) and reattach to pick up the new binary

## Important

- This runs on the **host**, not inside the container
- The update modifies the container's installed packages — this persists until the container is recreated
- If the container is rebuilt (docker compose down/up), it will revert to the image's bundled version
- To make updates permanent across rebuilds, the Docker image itself needs to be updated
