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

## Step 3 — Suggest 3–5 tasks

Pick concrete, completable items:
- Each fits in a single Claude session (under 10 minutes)
- Clear deliverables: files to create/modify, tests to write
- Ordered by dependency (no task depends on a later one)
- In multi-project mode: assign each task to the correct repo via `dir:`

---

## Step 4 — Iterate

Ask if the user wants to adjust, add, remove, or reprioritize. Revise until they confirm.

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

---
desc: Short task name
timeout: 600
dir: /home/dev/myproject
prompt: Detailed Claude instruction. Name specific files and patterns to follow.
  Indented lines continue the prompt. End with: Run tests. Commit with descriptive message.

---
desc: Next task
dir: /home/dev/other-project
prompt: Another self-contained instruction.
  Be specific. Claude has no conversation context when running this. Run tests. Commit.
```

Fields:
- `---` separates tasks
- `desc:` short name (required)
- `prompt:` multi-line instruction (required) — self-contained, no references to this conversation
- `timeout:` seconds, default 600 (optional)
- `dir:` working directory (optional — required in multi-project mode)

## Prompt quality checklist

Before finalising each prompt, verify:
- [ ] Names specific files or directories (not "the codebase")
- [ ] References existing patterns to follow (e.g. "follow src/api/users.ts")
- [ ] States what tests to write and where
- [ ] Ends with: `Run tests. Commit with descriptive message.`
- [ ] Fully self-contained — no references to "what we discussed"
