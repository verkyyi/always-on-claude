#!/usr/bin/env bash

set -euo pipefail

DASHBOARD_REPO="${DASHBOARD_REPO:-$HOME/projects/dashboard}"
SCHEDULE_ROOT="${AOC_SCHEDULE_ROOT:-$HOME/.always-on-claude/schedule}"
STATUS_DIR="$SCHEDULE_ROOT/status"
LOG_DIR="$SCHEDULE_ROOT/logs"
STATUS_FILE="$STATUS_DIR/apple-calendar-host.json"
LOG_FILE="$LOG_DIR/apple-calendar-host.log"
JOB_ID="apple-calendar-host"
LABEL="apple-calendar-host"

mkdir -p "$STATUS_DIR" "$LOG_DIR"

now_iso() {
  date "+%Y-%m-%dT%H:%M:%S%z"
}

slot_label() {
  date "+%Y-%m-%dT%H:%M"
}

write_status() {
  local status="$1"
  local run_status="$2"
  local started_at="$3"
  local finished_at="$4"
  local exit_code="$5"
  cat >"$STATUS_FILE" <<EOF
{
  "id": "$JOB_ID",
  "label": "$LABEL",
  "status": "$status",
  "last_run_status": "$run_status",
  "last_started_at": "$started_at",
  "last_finished_at": "$finished_at",
  "last_started_slot": "$(slot_label)",
  "last_finished_slot": "$(slot_label)",
  "last_run_mode": "scheduled",
  "last_exit_code": $exit_code,
  "log_file": "$LOG_FILE"
}
EOF
}

started_at="$(now_iso)"
echo "=== apple-calendar-host $started_at ===" >>"$LOG_FILE"
write_status "running" "running" "$started_at" "" 0

if /usr/bin/env python3 "$DASHBOARD_REPO/dashboard/fetch_apple_calendar_host.py" >>"$LOG_FILE" 2>&1; then
  finished_at="$(now_iso)"
  write_status "scheduled" "succeeded" "$started_at" "$finished_at" 0
  echo "ok: apple-calendar-host" >>"$LOG_FILE"
  echo "=== done $finished_at ===" >>"$LOG_FILE"
else
  rc=$?
  finished_at="$(now_iso)"
  write_status "scheduled" "failed" "$started_at" "$finished_at" "$rc"
  echo "fail: apple-calendar-host (rc=$rc)" >>"$LOG_FILE"
  echo "=== done $finished_at ===" >>"$LOG_FILE"
  exit "$rc"
fi

