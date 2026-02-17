#!/bin/bash
# git-check.sh — Daily repository health check
#
# For each git repo under /home:
#   1. Git health  — uncommitted changes, unpushed commits, stale branches
#   2. Code quality — linting, formatting, naming consistency   (via claude)
#   3. Test coverage — run test suite, flag untested files       (via claude)
#   4. Documentation — README, docstrings, function-level docs   (via claude)
#   5. Auto-fix     — formatter/linter fixes, committed locally  (via claude)
#   6. GitHub issues — filed for non-trivial unfixed problems    (via claude)
#
# Usage:
#   bash ~/dev-env/git-check.sh
#   LOG=/tmp/mylog.log bash ~/dev-env/git-check.sh
#   SKIP_ANALYSIS=1 bash ~/dev-env/git-check.sh   # git checks only, no claude
#
# Requirements: claude CLI, gh CLI (for issue creation)

LOG="${LOG:-$HOME/git-check.log}"
START_TIME=$(date +%s)
STALE_THRESHOLD=$(( START_TIME - 2592000 ))   # 30 days in seconds
ANALYSIS_TIMEOUT=600                           # 10 min per repo

{
echo "========================================================================"
echo "Repo Health Check — $(date)"
echo "========================================================================"
echo ""

REPOS=$(find "$HOME" -maxdepth 3 -name ".git" -type d 2>/dev/null)

if [ -z "$REPOS" ]; then
  echo "No git repositories found under /home."
  echo ""
fi

for git_dir in $REPOS; do
  repo="${git_dir%/.git}"

  echo "──────────────────────────────────────────────────────────────────────"
  echo "REPO: $repo"
  echo "──────────────────────────────────────────────────────────────────────"

  # ── 1. GIT HEALTH (shell, always runs) ──────────────────────────────────
  echo ""
  echo "[1/4] Git status"
  git_flagged=0

  status_output=$(git -C "$repo" status --short 2>/dev/null)
  if [ -n "$status_output" ]; then
    echo "  uncommitted / untracked:"
    echo "$status_output" | sed 's/^/    /'
    git_flagged=1
  fi

  unpushed=$(git -C "$repo" log '@{u}..HEAD' --oneline 2>/dev/null)
  if [ -n "$unpushed" ]; then
    echo "  unpushed commits:"
    echo "$unpushed" | sed 's/^/    /'
    git_flagged=1
  fi

  while IFS= read -r line; do
    branch=$(echo "$line" | awk '{print $1}')
    commit_ts=$(echo "$line" | awk '{print $2}')
    if [ -n "$commit_ts" ] && [ "$commit_ts" -lt "$STALE_THRESHOLD" ] 2>/dev/null; then
      if [ "$git_flagged" -eq 0 ]; then
        echo "  stale branches (>30 days):"
        git_flagged=1
      fi
      day=$(date -d "@$commit_ts" '+%Y-%m-%d' 2>/dev/null \
            || date -r "$commit_ts" '+%Y-%m-%d' 2>/dev/null)
      echo "    $branch (last commit: $day)"
    fi
  done < <(git -C "$repo" for-each-ref \
    --format='%(refname:short) %(committerdate:unix)' refs/heads/ 2>/dev/null)

  [ "$git_flagged" -eq 0 ] && echo "  (clean)"

  # ── 2–6. DEEP ANALYSIS VIA CLAUDE ───────────────────────────────────────
  if [ "${SKIP_ANALYSIS:-0}" = "1" ]; then
    echo ""
    continue
  fi

  if ! command -v claude &>/dev/null; then
    echo ""
    echo "[analysis skipped — claude CLI not found]"
    echo ""
    continue
  fi

  # Decide whether GH issue creation is possible
  gh_remote=$(git -C "$repo" remote get-url origin 2>/dev/null \
              | grep -E 'github\.com' || true)

  if [ -n "$gh_remote" ]; then
    issue_instr="The repo has a GitHub remote. Use:
  gh issue create --title \"<title>\" --body \"<body>\"
to file issues for significant, actionable problems only.
Apply label 'health-check' if it exists (gh label list to check), otherwise omit --label.
Do NOT create duplicate issues — check existing ones first with: gh issue list --state open"
  else
    issue_instr="No GitHub remote detected — skip issue creation. List problems in the summary instead."
  fi

  echo ""
  echo "[2–6] Deep analysis (claude, timeout ${ANALYSIS_TIMEOUT}s) ..."

  read -r -d '' PROMPT << PROMPT_EOF
You are performing a daily health check on the git repository at: $repo

Work through each section below. Be efficient — do not spend more than 90 seconds on any single check. After all sections, print the HEALTH_SUMMARY block exactly as specified.

---
### Section 1 — Code Consistency
- Detect the primary language(s) from files present.
- Run any linter whose config file exists (.eslintrc*, .pylintrc, pyproject.toml [tool.ruff/flake8], .rubocop.yml, golangci.yml, etc.).
- Run any formatter in check-or-fix mode (prettier --write, black ., gofmt -w, rustfmt, etc.).
- Identify: mixed naming conventions, dead code, large commented-out blocks, stale TODO/FIXME (older than 60 days if you can tell).

### Section 2 — Test Coverage
- Identify the test runner (jest, vitest, pytest, go test, cargo test, etc.).
- Run the tests. Report: total / passing / failing.
- Run with coverage if the flag is cheap (jest --coverage, pytest --cov=., go test -cover). Report overall %.
- List source files >100 lines that have no corresponding test file.

### Section 3 — Documentation
- Does README.md exist and contain more than boilerplate (>10 meaningful lines)?
- Are there exported/public functions, classes, or modules with no docstring / JSDoc / godoc comment?
- Is there a CHANGELOG or API doc if the project looks public-facing?
- Note gaps, do not fix them (documentation decisions belong to the human).

### Section 4 — Auto-Fix
- Apply safe, automated fixes only:
  - Formatter output (prettier, black, gofmt, etc.)
  - Auto-fixable lint rules (eslint --fix, ruff --fix, etc.)
  - Do NOT rewrite logic, rename public APIs, or delete files.
- If any files were changed, commit them:
  git add -A && git commit -m "chore: automated health-check fixes [skip ci]"
- Do NOT push or open a PR.

### Section 5 — GitHub Issues
$issue_instr

File issues for (examples, adapt to what you actually found):
- Test coverage below 60% overall, or a module with 0 tests
- Missing or empty README
- Consistent pattern of undocumented public API
- Non-trivial code inconsistency that requires a human decision

Do NOT file issues for: minor style preferences, single stray TODO, or anything already captured in an open issue.

---
### Required Output Block
After finishing all sections, print this block — fill in real values, keep the exact delimiters:

HEALTH_SUMMARY_START
repo:         $repo
consistency:  [ok|warnings|errors] — <one-line description>
tests:        [ok|warnings|errors|none] — <one-line description>
docs:         [ok|warnings|gaps] — <one-line description>
fixes:        [none|N files changed] — <list filenames if any>
issues:       [none|N created] — <titles, one per line>
HEALTH_SUMMARY_END
PROMPT_EOF

  (
    cd "$repo" || exit 1
    # Unset CLAUDECODE so this works when invoked inside an existing Claude session
    # (e.g. during testing). Cron runs don't have this variable set.
    unset CLAUDECODE
    timeout "$ANALYSIS_TIMEOUT" claude --dangerously-skip-permissions -p "$PROMPT" 2>&1
  )

  echo ""
  echo "----------------------------------------------------------------------"
  echo ""
done

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
echo "========================================================================"
echo "Health check completed in ${ELAPSED}s — $(date)"
echo "========================================================================"
echo ""
} >> "$LOG" 2>&1
