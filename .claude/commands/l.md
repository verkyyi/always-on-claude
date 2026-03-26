# Logs (mobile-friendly)

Show recent logs. Keep output short — summarize rather than dumping full logs.

## Steps

1. Detect available log sources:

   ```bash
   echo "=== Log sources ==="
   docker compose ps --format '{{.Name}}' 2>/dev/null && echo "(docker compose)" || true
   [[ -f package.json ]] && echo "(node project)" || true
   ls *.log 2>/dev/null && echo "(log files)" || true
   journalctl --no-pager -n 1 2>/dev/null && echo "(systemd)" || true
   ```

2. Show the most relevant logs (last 30 lines by default):

   - **Docker Compose services**:

     ```bash
     docker compose logs --tail=30 --no-log-prefix 2>/dev/null || true
     ```

   - **Log files** in current directory:

     ```bash
     for f in *.log; do echo "--- $f (last 10) ---"; tail -10 "$f"; done 2>/dev/null || true
     ```

   - **systemd journal** (if applicable):

     ```bash
     journalctl --no-pager -n 30 2>/dev/null || true
     ```

3. Summarize what you see: any errors, warnings, or notable entries. Lead with problems.

## Important

- Default to showing only 30 lines — ask before showing more
- Highlight errors and warnings first
- If the user asks for more, show the next batch rather than the full log
- Use `--since` for time-based filtering if the user asks for "last hour" etc.
