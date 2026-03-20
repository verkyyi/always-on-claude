# Status (mobile-friendly)

Quick status overview. Keep output compact — one line per item, no tables wider than 50 columns.

## Steps

1. Show git status for the current working directory:
   ```bash
   echo "BRANCH: $(git branch --show-current 2>/dev/null || echo 'not a repo')"
   git status --short 2>/dev/null | head -20 || true
   ```

2. Show recent commits (last 5, oneline):
   ```bash
   git log --oneline -5 2>/dev/null || true
   ```

3. Check for open PRs in this repo:
   ```bash
   gh pr list --limit 5 --state open 2>/dev/null || echo "gh not configured or not a GitHub repo"
   ```

4. Check instance health (container, disk, memory):
   ```bash
   docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null || echo "docker not available"
   df -h / 2>/dev/null | tail -1 | awk '{print "DISK: " $3 "/" $2 " (" $5 " used)"}'
   free -h 2>/dev/null | awk '/^Mem:/{print "MEM: " $3 "/" $2 " used"}' || true
   ```

5. Check for pending updates:
   ```bash
   [[ -f ~/.update-pending ]] && echo "UPDATE: pending — run /update to apply" || echo "UPDATE: up to date"
   ```

## Output format

Present everything as a compact single-screen summary. Example:

```
Branch: main (clean)
Last: 2h ago "Add feature X"
PRs: 2 open
Container: claude-dev Up 3 days
Disk: 12G/50G (24%)
Mem: 1.2G/4G
Update: up to date
```
