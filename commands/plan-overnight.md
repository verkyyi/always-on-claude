You are helping the user plan their overnight automated task run. The goal is to have a collaborative conversation about what Claude should work on tonight, then write a `tasks-<project>.txt` file and optionally schedule it to run automatically.

## Context

- Current directory: !`pwd`
- In a git repo: !`git rev-parse --show-toplevel 2>/dev/null && echo "yes" || echo "no"`
- Git repos found here: !`find "$(pwd)" -maxdepth 2 -name ".git" -type d 2>/dev/null | sed 's|/.git$||' | sort`

**Single-project context** (used when "In a git repo" is `yes`):
- Project name: !`basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"`
- GitHub remote: !`git remote get-url origin 2>/dev/null | sed 's/.*github.com[:/]//' | sed 's/.git$//' || echo "none"`
- Current branch: !`git branch --show-current 2>/dev/null || echo "unknown"`
- Recent commits: !`git log --oneline -10 2>/dev/null || echo "no history"`
- Open GitHub issues: !`gh issue list --limit 15 2>/dev/null || echo "none"`
- TODO list: !`cat TODO.md 2>/dev/null || cat docs/TODO.md 2>/dev/null || echo "no TODO.md"`

**Always:**
- Existing task files: !`ls ~/tasks-*.txt 2>/dev/null || echo "none"`
- Already scheduled: !`atq 2>/dev/null || echo "none (or 'at' not installed)"`

---

## Step 1 — Determine mode automatically

Look at the "In a git repo" value above:

**`yes` → Single-project mode**
- The current repo is the target. All single-project context is already loaded above.
- `$ARGUMENTS` (if given) is treated as a focus area keyword — prioritise matching items.

**`no` → Multi-project mode**
- Use the "Git repos found here" list. Those are the candidate projects.
- If the list is empty, tell the user no git repos were found under the current directory and ask them to `cd` to the right folder.
- For each repo in the list, use your Bash tool to gather:
  ```bash
  cat <repo>/TODO.md 2>/dev/null || echo "no TODO.md"
  gh issue list --repo <owner>/<name> --limit 10 2>/dev/null
  git -C <repo> log --oneline -5 2>/dev/null
  git -C <repo> remote get-url origin 2>/dev/null
  ```
- `$ARGUMENTS` (if given) is a focus area — filter to matching items across repos.

---

## Step 2 — Show available work

Present a concise summary:
- Unfinished TODO items (with repo label in multi-project mode)
- Open GitHub issues (grouped by theme if many)
- Recent activity — what's been worked on, what's stalled

---

## Step 3 — Suggest tasks targeting ~6 hours total runtime

**Task sizes:**
| Size | Timeout | Examples |
|------|---------|---------|
| S — 15 min | `900` | Small fix, add a test, update a config, simple util function |
| M — 30 min | `1800` | New endpoint, refactor a module, add validation + tests |
| L — 60 min | `3600` | New feature, multi-file refactor, integration with external service |

**Target:** fill ~360 minutes (6 hours). A balanced mix might be 2L + 4M + 6S = 330 min, or 12 × M = 360 min. Adjust to fit the available work.

After each suggestion, show the running total:
> Estimated total: **2h 30min** (3 tasks — 1L, 2M) — targeting 6h, room for ~3h 30min more

Rules:
- Ordered by dependency — no task depends on a later one
- Each prompt is fully self-contained (Claude has no memory between tasks)
- Prefer more smaller tasks over fewer large ones when work items are independent
- In multi-project mode: assign each task to the correct repo via `dir:`

---

## Step 4 — Iterate

Ask if the user wants to adjust, add, remove, or reprioritize. After each change, show the updated time total:
> Estimated total: **5h 45min** (10 tasks — 2L, 4M, 4S)

Keep iterating until the user confirms and the total is close to 6 hours. If they have less work than 6 hours, that's fine — don't pad with unnecessary tasks.

---

## Step 5 — Write tasks file

Filename:
- Single-project: `~/tasks-<project-name>.txt`
- Multi-project: `~/tasks-multi-<YYYYMMDD>.txt`

Write the file using the format below.

---

## Step 6 — Offer scheduling

After writing the file, ask:

> **Schedule this to run automatically?**
> - `yes` — schedule with `at` (one-off tonight). What time? (default: 11:00 PM)
> - `cron` — recurring nightly job
> - `no` — I'll kick it off manually

**If `yes`:**
```bash
echo "bash /home/dev/dev-env/run-tasks.sh ~/tasks-<project>.txt" | at HH:MM
atq   # confirm queued
```

**If `cron`:**
Write `/tmp/run-tasks-<project>.cron`:
```
# Nightly task runner for <project>
0 23 * * * dev bash /home/dev/dev-env/run-tasks.sh ~/tasks-<project>.txt
```
Then tell the user:
```bash
sudo cp /tmp/run-tasks-<project>.cron /etc/cron.d/run-tasks-<project>
```

**If `no`:**
```bash
cat ~/tasks-<project>.txt
tmux new -s overnight
bash ~/dev-env/run-tasks.sh ~/tasks-<project>.txt
# Ctrl+A, D to detach
```

---

## tasks.txt format

```
# Tasks for <project> — YYYY-MM-DD
# Estimated total runtime: ~6h (2L + 4M + 4S)

---
desc: [L] Add OAuth2 login flow
timeout: 3600
dir: /home/dev/myproject
prompt: Implement OAuth2 login with Google in src/auth/. Add callback handler at
  /auth/google/callback, store session in Redis using the existing client in src/lib/redis.ts.
  Follow patterns in src/auth/local.ts. Write integration tests in tests/auth/.
  Run tests. Commit with descriptive message.

---
desc: [M] Add rate limiting to public API endpoints
timeout: 1800
dir: /home/dev/myproject
prompt: Add rate limiting to all routes in src/api/public/. Use express-rate-limit,
  follow the existing middleware pattern in src/middleware/auth.ts.
  Limit to 100 req/min per IP. Write tests in tests/api/. Run tests. Commit.

---
desc: [S] Fix typo in error messages across src/api/
timeout: 900
dir: /home/dev/myproject
prompt: Find and fix all typos in user-facing error messages in src/api/.
  Run tests to confirm nothing broke. Commit with descriptive message.
```

Fields:
- `---` separates tasks
- `desc:` short name — prefix with `[S]`, `[M]`, or `[L]` for size (required)
- `prompt:` multi-line instruction (required) — self-contained, no references to this conversation
- `timeout:` seconds — use 900 (S), 1800 (M), or 3600 (L) (required)
- `dir:` working directory (optional — required in multi-project mode)

## Prompt quality checklist

Before finalising each prompt, verify:
- [ ] Names specific files or directories (not "the codebase")
- [ ] References existing patterns to follow (e.g. "follow src/api/users.ts")
- [ ] States what tests to write and where
- [ ] Ends with: `Run tests. Commit with descriptive message.`
- [ ] Fully self-contained — no references to "what we discussed"
