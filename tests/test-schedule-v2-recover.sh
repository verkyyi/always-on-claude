#!/bin/bash
# Tests for scripts/runtime/schedule-v2-recover.sh

RECOVER="$REPO_ROOT/scripts/runtime/schedule-v2-recover.sh"

setup() {
    mkdir -p \
        "$TEST_DIR/schedule/jobs" \
        "$TEST_DIR/schedule/status" \
        "$TEST_DIR/schedule/logs" \
        "$TEST_DIR/schedule/runs" \
        "$TEST_DIR/schedule/locks" \
        "$TEST_DIR/bin"
    export AOC_SCHEDULE_DIR="$TEST_DIR/schedule"

    cat > "$TEST_DIR/bin/docker" <<'EOF'
#!/bin/bash
if [[ "$1" == "compose" ]]; then shift; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|-w) shift 2 ;;
    exec|-T) shift ;;
    dev) shift ;;
    bash) shift; [[ "${1:-}" == "-lc" ]] && shift; exec bash -lc "$1" ;;
    *) shift ;;
  esac
done
exit 1
EOF
    chmod +x "$TEST_DIR/bin/docker"
}

test_recovery_marks_outside_grace_slot_missed() {
    cat > "$TEST_DIR/schedule/jobs/job1.json" <<'EOF'
{
  "version": 2,
  "id": "job1",
  "label": "job-one",
  "timezone": "America/Los_Angeles",
  "schedule": {"type":"daily","hour":3,"minute":0},
  "grace_window_sec": 60,
  "cwd": "/home/dev/projects/app",
  "command": "echo too-late",
  "container_service": "dev",
  "enabled": true
}
EOF

    PATH="$TEST_DIR/bin:$PATH" bash "$RECOVER"

    local slot_file
    slot_file="$(find "$TEST_DIR/schedule/runs/job1" -name '*.json' -type f | head -1)"
    assert_file_exists "$slot_file"
    assert_eq "missed" "$(jq -r '.status' "$slot_file")"
}

test_recovery_runs_catchup_within_grace() {
    cat > "$TEST_DIR/schedule/jobs/job2.json" <<'EOF'
{
  "version": 2,
  "id": "job2",
  "label": "job-two",
  "timezone": "America/Los_Angeles",
  "schedule": {"type":"hourly","minute":0},
  "grace_window_sec": 7200,
  "cwd": "/home/dev/projects/app",
  "command": "echo catchup",
  "container_service": "dev",
  "enabled": true
}
EOF

    PATH="$TEST_DIR/bin:$PATH" bash "$RECOVER"

    local slot_file
    slot_file="$(find "$TEST_DIR/schedule/runs/job2" -name '*.json' -type f | head -1)"
    assert_file_exists "$slot_file"
    assert_eq "succeeded" "$(jq -r '.status' "$slot_file")"
    assert_eq "catchup" "$(jq -r '.run_mode' "$slot_file")"
}
