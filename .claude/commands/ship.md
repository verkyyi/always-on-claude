# Ship (mobile-friendly)

Merge a PR, deploy, and verify. One command to go from "approved PR" to "live in production."

## Steps

1. Find the current branch's PR:
   ```bash
   gh pr view --json number,title,state,reviewDecision,mergeable,headRefName 2>/dev/null || echo "no PR found"
   ```

   If no PR exists for the current branch, tell the user and stop.

2. Show a one-line summary and confirm:
   ```
   Ship PR #42 "Add feature X" (approved, mergeable)? [y/N]
   ```

   If the PR is not approved or not mergeable, warn the user and ask if they want to proceed anyway.

3. Merge the PR:
   ```bash
   gh pr merge --squash --delete-branch
   ```

4. Switch to main and pull:
   ```bash
   git checkout main && git pull
   ```

5. Deploy (same logic as `/d`):
   - Detect project type and run the appropriate deploy command
   - Show only the last few lines of output

6. Verify health:
   ```bash
   # For docker compose:
   docker compose ps 2>/dev/null || true
   # For web apps, check if the service responds:
   curl -sf http://localhost:${PORT:-3000}/health 2>/dev/null && echo "HEALTHY" || echo "No health endpoint (check manually)"
   ```

7. Report final status in 2-3 lines:
   ```
   Shipped PR #42 "Add feature X"
   Deployed to main
   Health: OK
   ```

## Important

- Always confirm before merging
- If merge fails, show the error and stop — don't force merge
- If deploy fails after merge, report the error clearly
- Use --squash by default (cleaner history) — user can request --merge or --rebase
