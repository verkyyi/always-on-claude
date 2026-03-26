# Review (mobile-friendly)

Summarize open PRs and help approve/merge them. Optimized for quick review from a phone.

## Steps

1. List open PRs:

   ```bash
   gh pr list --state open --json number,title,author,createdAt,additions,deletions,reviewDecision --limit 10 2>/dev/null || echo "gh not configured"
   ```

2. Present a compact summary:

   ```text
   Open PRs:
   #42 "Add feature X" by alice (+50/-10) needs-review
   #41 "Fix bug Y" by bob (+5/-3) approved
   #39 "Update deps" by dependabot (+20/-15) needs-review
   ```

3. Ask the user which PR to review (by number), or if they want to approve/merge one directly.

4. When reviewing a specific PR, show:

   ```bash
   gh pr view NUMBER --json title,body,files,commits
   gh pr diff NUMBER
   ```

   - Summarize the changes in 3-5 bullet points
   - Note any concerns or suggestions
   - Keep the diff summary concise — mention files changed and the gist of each change

5. Based on user input:
   - **Approve**: `gh pr review NUMBER --approve --body "LGTM"`
   - **Request changes**: `gh pr review NUMBER --request-changes --body "MESSAGE"`
   - **Merge**: `gh pr merge NUMBER --squash --delete-branch`
   - **Comment**: `gh pr review NUMBER --comment --body "MESSAGE"`

## Important

- Lead with the summary, not the full diff
- For large PRs (>500 lines), summarize by file instead of showing the full diff
- Ask before approving or merging — never auto-approve
- Show review decision status (approved, changes-requested, pending) for each PR
