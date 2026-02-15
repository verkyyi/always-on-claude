#!/bin/bash
# overnight-tasks.sh — Autonomous Claude Code task runner.
# Edit the tasks below, then run inside a tmux session:
#
#   tmux new -s overnight
#   cd ~/project
#   bash ~/dev-env/overnight-tasks.sh
#   # Detach: Ctrl+A, then D

LOG_FILE="overnight-$(date +%Y%m%d-%H%M).md"
START_COMMIT=$(git rev-parse HEAD)

echo "# Overnight Run — $(date)" > "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Load secrets from SSM Parameter Store
source ~/dev-env/load-secrets.sh

run_task() {
  local task_num=$1
  local description=$2
  local prompt=$3

  echo "## Task $task_num: $description" >> "$LOG_FILE"
  echo "Started: $(date)" >> "$LOG_FILE"

  if timeout 600 claude -p "$prompt" --dangerously-skip-permissions 2>&1 | tail -50 >> "$LOG_FILE"; then
    echo "**Status: Completed**" >> "$LOG_FILE"
  else
    echo "**Status: Failed**" >> "$LOG_FILE"
  fi
  echo "" >> "$LOG_FILE"
}

# ============================================================
# Define your tasks here. Each gets a 10-minute timeout.
# ============================================================

run_task 1 "Example: Add input validation" \
  "Add input validation to all API endpoints in src/api/. Write tests. Run tests. Commit with descriptive message."

run_task 2 "Example: Rate limiting" \
  "Add rate limiting to all public endpoints. Use express-rate-limit. Write tests. Run tests. Commit."

run_task 3 "Example: Error handling" \
  "Improve error handling across the codebase. Add structured error types. Test. Commit."

# ============================================================
# Summary — don't edit below this line
# ============================================================

echo "## Git Summary" >> "$LOG_FILE"
echo '```' >> "$LOG_FILE"
git log --oneline "$START_COMMIT"..HEAD >> "$LOG_FILE"
echo '```' >> "$LOG_FILE"

echo "## Diff Stats" >> "$LOG_FILE"
echo '```' >> "$LOG_FILE"
git diff --stat "$START_COMMIT"..HEAD >> "$LOG_FILE"
echo '```' >> "$LOG_FILE"

echo "## Final Test Results" >> "$LOG_FILE"
echo '```' >> "$LOG_FILE"
npm test 2>&1 | tail -30 >> "$LOG_FILE"
echo '```' >> "$LOG_FILE"

# Push so you can pull from your laptop in the morning
git push origin main

echo "Done! Summary: $LOG_FILE"
