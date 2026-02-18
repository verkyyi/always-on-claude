#!/bin/bash
# trigger-watcher.sh — Host-side watcher for overnight task scheduling.
#
# Run on the HOST via cron every minute:
#   * * * * * ubuntu bash ~/dev-env/trigger-watcher.sh >> ~/overnight/trigger-watcher.log 2>&1
#
# How it works:
#   1. plan-overnight (inside container) writes ~/overnight/tasks-<name>.txt.scheduled
#      containing a single line: the target time (e.g. "23:00" or "now + 2 hours")
#   2. This script detects the sidecar, schedules docker exec via `at`, then
#      renames it to .triggered to prevent re-scheduling
#   3. Logs everything to ~/overnight/trigger-watcher.log

OVERNIGHT_DIR="$HOME/overnight"
CONTAINER_NAME="claude-dev"
LOG_PREFIX="[trigger-watcher $(date '+%Y-%m-%d %H:%M:%S')]"

# Nothing to do if no sidecars exist
sidecars=("$OVERNIGHT_DIR"/*.scheduled)
[[ -f "${sidecars[0]}" ]] || exit 0

for sidecar in "${sidecars[@]}"; do
  [[ -f "$sidecar" ]] || continue

  # Read the scheduled time from the sidecar (e.g. "23:00" or "now + 5 minutes")
  target_time=$(cat "$sidecar" | tr -d '[:space:]')
  [[ -z "$target_time" ]] && target_time="23:00"

  # Derive the tasks file path (strip .scheduled suffix)
  tasks_file="${sidecar%.scheduled}"

  # Skip if the tasks file doesn't exist
  if [[ ! -f "$tasks_file" ]]; then
    echo "$LOG_PREFIX Sidecar found but tasks file missing: $tasks_file — skipping" >&2
    mv "$sidecar" "${sidecar%.scheduled}.error"
    continue
  fi

  # Container-relative path (host ~/overnight maps to container ~/overnight)
  container_tasks_file="${tasks_file/$HOME/\/home\/dev}"

  # Schedule via at on the host — docker exec runs outside any Claude session
  job_cmd="docker exec $CONTAINER_NAME bash -c 'bash ~/dev-env/run-tasks.sh $container_tasks_file'"
  if echo "$job_cmd" | at "$target_time" 2>/dev/null; then
    echo "$LOG_PREFIX Scheduled: $tasks_file at $target_time"
    mv "$sidecar" "${sidecar%.scheduled}.triggered"
  else
    echo "$LOG_PREFIX Failed to schedule: $tasks_file at $target_time — is 'at' installed and atd running?" >&2
    mv "$sidecar" "${sidecar%.scheduled}.error"
  fi
done
